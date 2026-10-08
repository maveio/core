package main

import (
	"archive/zip"
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	_ "embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"log"
	"math"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const maxRequestBytes = 1024 * 1024
const instanceHeader = "X-Mave-Booster-Instance"
const readinessCacheTTL = 30 * time.Second
const defaultBundleTempDir = "/var/tmp"
const placeholderOverlayName = "mave-placeholder-overlay.png"
const ffmpegExecutable = "ffmpeg"
const maxWarmupHold = 30 * time.Second
const multipartHeartbeatInterval = 10 * time.Second
const maxSeekableFrameBytes = 64 * 1024 * 1024
const productionEncodingProfile = "mave-production-v2"
const legacyProductionEncodingProfile = "mave-production-v1"
const productionSVTAV1Params = "pin-threads=0:set-thread-priority=0:no-set-thread-priority=1:hierarchical-levels=4:tile-threads=0:log-level=1:tune=0"
const legacyProductionSVTAV1Params = "pin-threads=0:set-thread-priority=0:no-set-thread-priority=1:hierarchical-levels=4:tile-threads=0:log-level=1"
const safeInputFormats = "aac,aiff,amr,avi,flac,flv,matroska,webm,mov,mp3,mpeg,mpegts,mpegvideo,ogg,wav"
const safeFrameInputFormats = safeInputFormats + ",jpeg_pipe,png_pipe"

var lookupSourceIPs = net.DefaultResolver.LookupIPAddr
var dialSourceContext = (&net.Dialer{}).DialContext
var performSourceRequest = executePublicSourceRequest

var blockedSourceIPPrefixes = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"),
	netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("127.0.0.0/8"),
	netip.MustParsePrefix("169.254.0.0/16"),
	netip.MustParsePrefix("192.0.0.0/24"),
	netip.MustParsePrefix("192.0.2.0/24"),
	netip.MustParsePrefix("192.88.99.0/24"),
	netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("198.51.100.0/24"),
	netip.MustParsePrefix("203.0.113.0/24"),
	netip.MustParsePrefix("240.0.0.0/4"),
	netip.MustParsePrefix("2001::/27"),
	netip.MustParsePrefix("2001:db8::/32"),
	netip.MustParsePrefix("2002::/16"),
}

func sanitizedFFmpegDetails(output string, inputURLs ...string) string {
	details := strings.TrimSpace(output)
	for _, inputURL := range inputURLs {
		if inputURL != "" {
			details = strings.ReplaceAll(details, inputURL, "<input-url>")
		}
	}
	if len(details) > 2_000 {
		details = details[len(details)-2_000:]
	}
	return details
}

func ffmpegSourceRedactions(inputURL string, inputBasicAuth string) []string {
	redactions := []string{inputURL}
	if inputBasicAuth != "" {
		redactions = append(redactions, base64.StdEncoding.EncodeToString([]byte(inputBasicAuth)))
	}
	return redactions
}

var ffmpegMetricHeaders = map[string]string{
	"frame":       "X-Mave-FFmpeg-Frames",
	"fps":         "X-Mave-FFmpeg-Fps",
	"speed":       "X-Mave-FFmpeg-Speed",
	"out_time_ms": "X-Mave-FFmpeg-Out-Time-Ms",
	"total_size":  "X-Mave-FFmpeg-Output-Bytes",
	"dup_frames":  "X-Mave-FFmpeg-Dup-Frames",
	"drop_frames": "X-Mave-FFmpeg-Drop-Frames",
}

var bitratePattern = regexp.MustCompile(`^[1-9][0-9]{0,5}[kKmM]$`)
var hlsFilePattern = regexp.MustCompile(`^segment_[0-9]{3,6}\.m4s$`)
var presets = map[string]bool{
	"ultrafast": true, "superfast": true, "veryfast": true, "faster": true,
	"fast": true, "medium": true, "slow": true, "slower": true,
	"veryslow": true, "placebo": true,
}
var tunes = map[string]bool{
	"film": true, "animation": true, "grain": true, "stillimage": true,
	"fastdecode": true, "zerolatency": true, "psnr": true, "ssim": true,
}

type encodeRequest struct {
	InputURL                string           `json:"input_url"`
	InputBasicAuth          string           `json:"-"`
	InputReferer            string           `json:"input_referer,omitempty"`
	EncodingProfile         string           `json:"encoding_profile,omitempty"`
	Operation               string           `json:"operation,omitempty"`
	Codec                   string           `json:"codec,omitempty"`
	AudioCodec              string           `json:"audio_codec,omitempty"`
	AudioStreamIndex        int              `json:"audio_stream_index,omitempty"`
	FrameRole               string           `json:"frame_role,omitempty"`
	FrameCodec              string           `json:"frame_codec,omitempty"`
	Width                   int              `json:"width,omitempty"`
	VideoBitrate            string           `json:"video_bitrate,omitempty"`
	VideoCRF                int              `json:"video_crf,omitempty"`
	SVTAV1Params            string           `json:"svt_av1_params,omitempty"`
	AudioBitrate            string           `json:"audio_bitrate,omitempty"`
	Preset                  string           `json:"preset,omitempty"`
	Tune                    string           `json:"tune,omitempty"`
	IncludeAudio            *bool            `json:"include_audio,omitempty"`
	KeyframeIntervalSeconds int              `json:"keyframe_interval_seconds,omitempty"`
	GOPFrames               int              `json:"gop_frames,omitempty"`
	StartSeconds            float64          `json:"start_seconds,omitempty"`
	DurationSeconds         float64          `json:"duration_seconds,omitempty"`
	MaxDurationSeconds      int              `json:"max_duration_seconds,omitempty"`
	PackageHLS              bool             `json:"package_hls,omitempty"`
	OutputUpload            *multipartUpload `json:"output_upload,omitempty"`
	OutputUploads           []assetUpload    `json:"output_uploads,omitempty"`
	Count                   int              `json:"count,omitempty"`
}

type assetUpload struct {
	Name         string          `json:"name"`
	OutputUpload multipartUpload `json:"output_upload"`
}

type multipartUpload struct {
	PartSizeBytes int64    `json:"part_size_bytes"`
	PartURLs      []string `json:"part_urls"`
	CompleteURL   string   `json:"complete_url"`
	AbortURL      string   `json:"abort_url"`
}

type uploadedPart struct {
	PartNumber int
	ETag       string
}

type uploadEvent struct {
	Status          string            `json:"status"`
	UploadedBytes   int64             `json:"uploaded_bytes,omitempty"`
	PartNumber      int               `json:"part_number,omitempty"`
	SizeBytes       int64             `json:"size_bytes,omitempty"`
	SHA256          string            `json:"sha256,omitempty"`
	FFmpegElapsedMS int64             `json:"ffmpeg_elapsed_ms,omitempty"`
	Error           string            `json:"error,omitempty"`
	Metrics         map[string]string `json:"metrics,omitempty"`
}

type packageHLSRequest struct {
	InputURL       string `json:"input_url"`
	InputBasicAuth string `json:"-"`
	InputReferer   string `json:"input_referer,omitempty"`
	UploadToken    string `json:"upload_token,omitempty"`
	MediaKind      string `json:"media_kind,omitempty"`
	Channels       int    `json:"channels,omitempty"`
}

type hlsFile struct {
	Name        string `json:"name"`
	Key         string `json:"key,omitempty"`
	ContentType string `json:"content_type,omitempty"`
	SizeBytes   int64  `json:"size_bytes"`
}

type hlsUploadRequest struct {
	Files []hlsFile `json:"files"`
}

type hlsPutDestination struct {
	URL     string            `json:"url"`
	Headers map[string]string `json:"headers"`
}

type hlsUploadTarget struct {
	Name        string            `json:"name"`
	Key         string            `json:"key"`
	ContentType string            `json:"content_type"`
	SizeBytes   int64             `json:"size_bytes"`
	Upload      hlsPutDestination `json:"upload"`
}

type hlsUploadResponse struct {
	Uploads []hlsUploadTarget `json:"uploads"`
}

type hlsUploadEvent struct {
	Status          string    `json:"status"`
	UploadedBytes   int64     `json:"uploaded_bytes,omitempty"`
	FileCount       int       `json:"file_count,omitempty"`
	FFmpegElapsedMS int64     `json:"ffmpeg_elapsed_ms,omitempty"`
	Files           []hlsFile `json:"files,omitempty"`
	Error           string    `json:"error,omitempty"`
}

type concatRequest struct {
	InputURLs    []string        `json:"input_urls"`
	InputReferer string          `json:"input_referer,omitempty"`
	OutputUpload multipartUpload `json:"output_upload"`
}

type transferRequest struct {
	InputURL       string          `json:"input_url"`
	InputReferer   string          `json:"input_referer,omitempty"`
	InputBasicAuth string          `json:"input_basic_auth,omitempty"`
	OutputUpload   multipartUpload `json:"output_upload"`
}

func (request *transferRequest) validate() error {
	parsed, err := url.ParseRequestURI(request.InputURL)
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" || parsed.User != nil {
		return errors.New("input_url must be an absolute HTTPS URL without credentials")
	}
	if request.InputReferer != "" {
		referer, err := url.ParseRequestURI(request.InputReferer)
		if err != nil || referer.Scheme != "https" || referer.Hostname() == "" || referer.User != nil ||
			strings.ContainsAny(request.InputReferer, "\r\n") || len(request.InputReferer) > 2048 {
			return errors.New("input_referer must be an absolute HTTPS URL without credentials")
		}
	}
	if len(request.InputBasicAuth) > 4096 || containsControlByte(request.InputBasicAuth) {
		return errors.New("input_basic_auth is invalid")
	}
	return request.OutputUpload.validate()
}

func containsControlByte(value string) bool {
	for index := 0; index < len(value); index++ {
		if value[index] < 32 || value[index] == 127 {
			return true
		}
	}
	return false
}

func publicSourceIP(ip net.IP) bool {
	address, valid := netip.AddrFromSlice(ip)
	if !valid {
		return false
	}
	address = address.Unmap()
	if !address.IsGlobalUnicast() || address.IsPrivate() {
		return false
	}
	if address.Is6() && !netip.MustParsePrefix("2000::/3").Contains(address) {
		return false
	}
	for _, prefix := range blockedSourceIPPrefixes {
		if prefix.Contains(address) {
			return false
		}
	}
	return true
}

func executePublicSourceRequest(request *http.Request) (*http.Response, error) {
	host := request.URL.Hostname()
	if host == "" {
		return nil, errors.New("source host is missing")
	}

	addresses, err := lookupSourceIPs(request.Context(), host)
	if err != nil || len(addresses) == 0 {
		return nil, errors.New("source host could not be resolved")
	}
	for _, address := range addresses {
		if !publicSourceIP(address.IP) {
			return nil, errors.New("source host resolved to a blocked address")
		}
	}

	selectedIP := addresses[0].IP.String()
	client, err := publicSourceHTTPClient(host, selectedIP)
	if err != nil {
		return nil, err
	}
	return client.Do(request)
}

func publicSourceHTTPClient(host string, selectedIP string) (*http.Client, error) {
	baseTransport, ok := http.DefaultTransport.(*http.Transport)
	if !ok {
		return nil, errors.New("source transport is unavailable")
	}
	transport := baseTransport.Clone()
	transport.Proxy = nil
	transport.DisableKeepAlives = true
	transport.DialContext = func(ctx context.Context, network string, address string) (net.Conn, error) {
		addressHost, addressPort, splitErr := net.SplitHostPort(address)
		if splitErr != nil || !strings.EqualFold(strings.TrimSuffix(addressHost, "."), strings.TrimSuffix(host, ".")) {
			return nil, errors.New("source connection target changed")
		}
		return dialSourceContext(ctx, network, net.JoinHostPort(selectedIP, addressPort))
	}

	client := &http.Client{
		Transport: transport,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	return client, nil
}

func (request *concatRequest) validate() error {
	if len(request.InputURLs) < 2 || len(request.InputURLs) > 64 {
		return errors.New("input_urls must contain between 2 and 64 URLs")
	}
	for _, inputURL := range request.InputURLs {
		parsed, err := url.ParseRequestURI(inputURL)
		if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" || parsed.User != nil {
			return errors.New("input_urls must contain absolute HTTPS URLs without credentials")
		}
	}
	if request.InputReferer != "" {
		referer, err := url.ParseRequestURI(request.InputReferer)
		if err != nil || referer.Scheme != "https" || referer.Hostname() == "" || referer.User != nil ||
			strings.ContainsAny(request.InputReferer, "\r\n") || len(request.InputReferer) > 2048 {
			return errors.New("input_referer must be an absolute HTTPS URL without credentials")
		}
	}
	return request.OutputUpload.validate()
}

func (request *packageHLSRequest) validate() error {
	encodeRequest := encodeRequest{
		InputURL:       request.InputURL,
		InputBasicAuth: request.InputBasicAuth,
		InputReferer:   request.InputReferer,
	}
	if err := encodeRequest.validateSource(); err != nil {
		return err
	}
	request.InputURL = encodeRequest.InputURL
	request.InputBasicAuth = encodeRequest.InputBasicAuth
	if request.MediaKind == "" {
		request.MediaKind = "video"
	}
	if request.MediaKind != "video" && request.MediaKind != "audio" {
		return errors.New("media_kind must be video or audio")
	}
	if request.Channels == 0 {
		request.Channels = 2
	}
	if request.Channels < 1 || request.Channels > 8 {
		return errors.New("channels must be between 1 and 8")
	}
	if len(request.UploadToken) > 16*1024 || strings.ContainsAny(request.UploadToken, "\r\n") {
		return errors.New("upload_token is invalid")
	}
	return nil
}

func (request *encodeRequest) validate() error {
	if err := request.validateSource(); err != nil {
		return err
	}
	if request.Operation == "" {
		request.Operation = "video"
	}
	switch request.Operation {
	case "video":
		return request.validateVideo()
	case "audio":
		return request.validateAudio()
	case "audio_peaks":
		return request.validateAudioPeaks()
	case "frame":
		return request.validateFrame()
	case "waveform":
		return request.validateWaveform()
	case "storyboard":
		return request.validateStoryboard()
	case "segments":
		return request.validateSegments()
	default:
		return errors.New("operation must be video, audio, audio_peaks, frame, waveform, storyboard, or segments")
	}
}

func (request *encodeRequest) validateSource() error {
	inputURL, inputBasicAuth, err := normalizeSourceInput(request.InputURL)
	if err != nil {
		return err
	}
	if inputBasicAuth == "" {
		inputBasicAuth = request.InputBasicAuth
	}
	if len(inputBasicAuth) > 4096 || containsControlByte(inputBasicAuth) {
		return errors.New("input_url credentials are invalid")
	}
	request.InputURL = inputURL
	request.InputBasicAuth = inputBasicAuth
	if request.InputReferer != "" {
		referer, err := url.ParseRequestURI(request.InputReferer)
		invalidReferer := err != nil || referer.Scheme != "https" || referer.Hostname() == "" ||
			referer.User != nil || strings.ContainsAny(request.InputReferer, "\r\n") ||
			len(request.InputReferer) > 2048
		if invalidReferer {
			return errors.New("input_referer must be an absolute HTTPS URL without credentials")
		}
	}
	if request.OutputUpload != nil {
		if err := request.OutputUpload.validate(); err != nil {
			return fmt.Errorf("output_upload: %w", err)
		}
	}
	for index := range request.OutputUploads {
		if err := request.OutputUploads[index].OutputUpload.validate(); err != nil {
			return fmt.Errorf("output_uploads[%d]: %w", index, err)
		}
	}
	return nil
}

func normalizeSourceInput(inputURL string) (string, string, error) {
	parsed, err := url.ParseRequestURI(inputURL)
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" {
		return "", "", errors.New("input_url must be an absolute HTTPS URL")
	}
	if parsed.User == nil {
		return inputURL, "", nil
	}

	encodedBasicAuth := parsed.User.String()
	if encodedBasicAuth == "" {
		return "", "", errors.New("input_url credentials are invalid")
	}
	inputBasicAuth, err := url.PathUnescape(encodedBasicAuth)
	if err != nil || len(inputBasicAuth) > 4096 || containsControlByte(inputBasicAuth) {
		return "", "", errors.New("input_url credentials are invalid")
	}

	parsed.User = nil
	return parsed.String(), inputBasicAuth, nil
}

func (request *encodeRequest) validateVideo() error {
	if len(request.OutputUploads) != 0 {
		return errors.New("output_uploads is supported only for segments")
	}
	if request.Width == 0 {
		request.Width = 1920
	}
	if request.Codec == "" {
		request.Codec = "h264"
	}
	if request.Codec != "h264" && request.Codec != "hevc" && request.Codec != "av1" {
		return errors.New("codec must be h264, hevc, or av1")
	}
	if request.Width < 320 || request.Width > 3840 || request.Width%2 != 0 {
		return errors.New("width must be an even number between 320 and 3840")
	}
	if request.EncodingProfile != "" && request.EncodingProfile != productionEncodingProfile && request.EncodingProfile != legacyProductionEncodingProfile {
		return errors.New("encoding_profile is not supported")
	}
	if request.EncodingProfile == "" {
		request.EncodingProfile = productionEncodingProfile
	}
	if request.VideoBitrate == "" && request.VideoCRF == 0 {
		request.VideoBitrate = "8M"
	}
	if request.VideoBitrate != "" {
		if err := validateBitrate(request.VideoBitrate, 80_000_000); err != nil {
			return fmt.Errorf("video_bitrate: %w", err)
		}
	}
	maxCRF := 51
	if request.Codec == "av1" {
		maxCRF = 63
	}
	if request.VideoCRF < 0 || request.VideoCRF > maxCRF {
		return fmt.Errorf("video_crf must be between 0 and %d", maxCRF)
	}
	if request.SVTAV1Params != "" {
		if request.Codec != "av1" || !validSVTAV1Params(request.EncodingProfile, request.SVTAV1Params) {
			return errors.New("svt_av1_params is not supported")
		}
	}
	if request.AudioBitrate == "" {
		request.AudioBitrate = "192k"
	}
	if err := validateBitrate(request.AudioBitrate, 512_000); err != nil {
		return fmt.Errorf("audio_bitrate: %w", err)
	}
	if request.Preset == "" {
		request.Preset = "medium"
	}
	if !presets[request.Preset] {
		return errors.New("preset is not allowed")
	}
	if request.Tune != "" && !tunes[request.Tune] {
		return errors.New("tune is not allowed")
	}
	if request.KeyframeIntervalSeconds < 0 || request.KeyframeIntervalSeconds > 60 {
		return errors.New("keyframe_interval_seconds must be between 0 and 60")
	}
	if request.GOPFrames < 0 || request.GOPFrames > 10_000 {
		return errors.New("gop_frames must be between 0 and 10000")
	}
	if request.StartSeconds < 0 || request.StartSeconds > 604_800 {
		return errors.New("start_seconds must be between 0 and 604800")
	}
	if request.DurationSeconds < 0 || request.DurationSeconds > 86_400 {
		return errors.New("duration_seconds must be between 0 and 86400")
	}
	if request.MaxDurationSeconds < 0 || request.MaxDurationSeconds > 86_400 {
		return errors.New("max_duration_seconds must be between 0 and 86400")
	}
	if request.PackageHLS && request.Codec != "h264" {
		return errors.New("package_hls is supported only for h264")
	}
	if request.PackageHLS && request.OutputUpload != nil {
		return errors.New("output_upload cannot be combined with package_hls")
	}
	return nil
}

func validSVTAV1Params(profile string, params string) bool {
	switch profile {
	case productionEncodingProfile:
		return params == productionSVTAV1Params
	case legacyProductionEncodingProfile:
		return params == legacyProductionSVTAV1Params
	default:
		return false
	}
}

func (request *encodeRequest) validateAudio() error {
	if len(request.OutputUploads) != 0 {
		return errors.New("output_uploads is supported only for segments")
	}
	if request.AudioCodec == "" {
		request.AudioCodec = "mp3"
	}
	if request.AudioCodec != "mp3" && request.AudioCodec != "aac" && request.AudioCodec != "wav" && request.AudioCodec != "opus" {
		return errors.New("audio_codec must be mp3, aac, wav, or opus")
	}
	if request.AudioStreamIndex < 0 || request.AudioStreamIndex > 63 {
		return errors.New("audio_stream_index must be between 0 and 63")
	}
	if request.AudioBitrate == "" {
		request.AudioBitrate = "128k"
	}
	if err := validateBitrate(request.AudioBitrate, 512_000); err != nil {
		return fmt.Errorf("audio_bitrate: %w", err)
	}
	if request.PackageHLS {
		return errors.New("package_hls is supported only for video")
	}
	return nil
}

func (request *encodeRequest) validateAudioPeaks() error {
	if math.IsNaN(request.DurationSeconds) || math.IsInf(request.DurationSeconds, 0) || request.DurationSeconds <= 0 || request.DurationSeconds > 86400 {
		return errors.New("audio_peaks duration_seconds must be between 0 and 86400")
	}
	if request.StartSeconds != 0 || request.PackageHLS || request.OutputUpload != nil || len(request.OutputUploads) != 0 {
		return errors.New("audio_peaks only supports a complete-track metadata response")
	}
	return nil
}

func (request *encodeRequest) validateFrame() error {
	if len(request.OutputUploads) != 0 {
		return errors.New("output_uploads is supported only for segments")
	}
	if request.FrameRole == "" {
		request.FrameRole = "frame"
	}
	if request.FrameRole != "poster" && request.FrameRole != "thumbnail" && request.FrameRole != "custom_thumbnail" && request.FrameRole != "placeholder" && request.FrameRole != "frame" {
		return errors.New("frame_role must be poster, thumbnail, custom_thumbnail, placeholder, or frame")
	}
	if request.FrameCodec == "" {
		request.FrameCodec = "jpg"
	}
	if request.FrameCodec != "jpg" && request.FrameCodec != "jpeg" && request.FrameCodec != "png" && request.FrameCodec != "webp" && request.FrameCodec != "avif" {
		return errors.New("frame_codec must be jpg, jpeg, png, webp, or avif")
	}
	if request.StartSeconds < 0 || request.StartSeconds > 604_800 {
		return errors.New("start_seconds must be between 0 and 604800")
	}
	if request.PackageHLS {
		return errors.New("package_hls is supported only for video")
	}
	return nil
}

func (request *encodeRequest) validateWaveform() error {
	if request.Codec == "" {
		request.Codec = "h264"
	}
	if request.Codec != "h264" {
		return errors.New("waveform codec must be h264")
	}
	if request.OutputUpload == nil || len(request.OutputUploads) != 0 {
		return errors.New("waveform requires exactly one output_upload")
	}
	if request.PackageHLS {
		return errors.New("package_hls is supported only for video")
	}
	return nil
}

func (request *encodeRequest) validateStoryboard() error {
	if err := request.validateAssetCodecAndDuration(); err != nil {
		return err
	}
	if request.Count == 0 {
		request.Count = 60
	}
	if request.Count < 1 || request.Count > 100 {
		return errors.New("storyboard count must be between 1 and 100")
	}
	if request.OutputUpload == nil || len(request.OutputUploads) != 0 {
		return errors.New("storyboard requires exactly one output_upload")
	}
	return nil
}

func (request *encodeRequest) validateSegments() error {
	if err := request.validateAssetCodecAndDuration(); err != nil {
		return err
	}
	if request.Count == 0 {
		request.Count = 6
	}
	if request.Count < 1 || request.Count > 20 {
		return errors.New("segments count must be between 1 and 20")
	}
	if request.OutputUpload != nil || len(request.OutputUploads) != request.Count {
		return errors.New("segments requires one named output_upload per segment")
	}
	seen := make(map[string]bool, request.Count)
	for index, output := range request.OutputUploads {
		expectedName := fmt.Sprintf("thumbnail_%d.%s", index, request.FrameCodec)
		if output.Name != expectedName || seen[output.Name] {
			return errors.New("segments output names must be unique and ordered")
		}
		seen[output.Name] = true
	}
	return nil
}

func (request *encodeRequest) validateAssetCodecAndDuration() error {
	if request.FrameCodec == "" {
		request.FrameCodec = "jpg"
	}
	if request.FrameCodec != "jpg" && request.FrameCodec != "jpeg" && request.FrameCodec != "webp" {
		return errors.New("asset frame_codec must be jpg, jpeg, or webp")
	}
	if request.DurationSeconds <= 0 || request.DurationSeconds > 604_800 {
		return errors.New("asset duration_seconds must be between 0 and 604800")
	}
	if request.PackageHLS {
		return errors.New("package_hls is supported only for video")
	}
	return nil
}

func (upload *multipartUpload) validate() error {
	if upload.PartSizeBytes < 5*1024*1024 || upload.PartSizeBytes > 512*1024*1024 {
		return errors.New("part_size_bytes must be between 5 MiB and 512 MiB")
	}
	if len(upload.PartURLs) == 0 || len(upload.PartURLs) > 1000 {
		return errors.New("part_urls must contain between 1 and 1000 URLs")
	}
	allURLs := append(append([]string{}, upload.PartURLs...), upload.CompleteURL, upload.AbortURL)
	var expectedHost string
	var expectedPath string
	for _, candidate := range allURLs {
		parsed, err := url.ParseRequestURI(candidate)
		if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" || parsed.User != nil {
			return errors.New("all upload URLs must be absolute HTTPS URLs without credentials")
		}
		if expectedHost == "" {
			expectedHost = parsed.Host
			expectedPath = parsed.EscapedPath()
		} else if parsed.Host != expectedHost || parsed.EscapedPath() != expectedPath {
			return errors.New("all upload URLs must target the same object-storage object")
		}
	}
	return nil
}

func validateBitrate(value string, maximum int64) error {
	if !bitratePattern.MatchString(value) {
		return errors.New("use a value such as 8M or 192k")
	}
	number, _ := strconv.ParseInt(value[:len(value)-1], 10, 64)
	multiplier := int64(1_000)
	if strings.EqualFold(value[len(value)-1:], "m") {
		multiplier = 1_000_000
	}
	if number*multiplier > maximum {
		return errors.New("value exceeds the allowed maximum")
	}
	return nil
}

func sendJSON(writer http.ResponseWriter, status int, payload map[string]string) {
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(status)
	_ = json.NewEncoder(writer).Encode(payload)
}

func newInstanceID() string {
	random := make([]byte, 8)
	if _, err := rand.Read(random); err == nil {
		return hex.EncodeToString(random)
	}
	return fmt.Sprintf("pid-%d-%d", os.Getpid(), time.Now().UnixNano())
}

type recentLog struct {
	mutex    sync.Mutex
	lines    []string
	progress map[string]string
}

type activityTracker struct {
	mutex        sync.Mutex
	active       int
	draining     bool
	lastActivity time.Time
}

func requestSlots(maxConcurrent int) chan struct{} {
	if maxConcurrent > 0 {
		return make(chan struct{}, maxConcurrent)
	}
	return nil
}

func newActivityTracker() *activityTracker {
	return &activityTracker{lastActivity: time.Now()}
}

func (tracker *activityTracker) tryBegin() (func(), bool) {
	tracker.mutex.Lock()
	if tracker.draining {
		tracker.mutex.Unlock()
		return nil, false
	}
	tracker.active++
	tracker.lastActivity = time.Now()
	tracker.mutex.Unlock()

	return func() {
		tracker.mutex.Lock()
		tracker.active--
		tracker.lastActivity = time.Now()
		tracker.mutex.Unlock()
	}, true
}

func (tracker *activityTracker) idleFor(minimum time.Duration) bool {
	tracker.mutex.Lock()
	defer tracker.mutex.Unlock()
	return tracker.active == 0 && time.Since(tracker.lastActivity) >= minimum
}

func (tracker *activityTracker) drainIfIdle(minimum time.Duration) bool {
	tracker.mutex.Lock()
	defer tracker.mutex.Unlock()

	if tracker.active != 0 || time.Since(tracker.lastActivity) < minimum {
		return false
	}

	tracker.draining = true
	return true
}

func (tracker *activityTracker) resume() {
	tracker.mutex.Lock()
	tracker.draining = false
	tracker.lastActivity = time.Now()
	tracker.mutex.Unlock()
}

func (tracker *activityTracker) accepting() bool {
	tracker.mutex.Lock()
	defer tracker.mutex.Unlock()
	return !tracker.draining
}

func (tracker *activityTracker) status() (accepting bool, active int) {
	tracker.mutex.Lock()
	defer tracker.mutex.Unlock()
	return !tracker.draining, tracker.active
}

type commandRunner func(context.Context, string, ...string) ([]byte, error)

type encoderReadiness struct {
	backend   string
	cacheTTL  time.Duration
	run       commandRunner
	mutex     sync.Mutex
	checkedAt time.Time
	err       error
}

func newEncoderReadiness(backend string, cacheTTL time.Duration, run commandRunner) *encoderReadiness {
	return &encoderReadiness{backend: backend, cacheTTL: cacheTTL, run: run}
}

func runCommand(context context.Context, executable string, args ...string) ([]byte, error) {
	return mediaCommandOutput(mediaCommand(context, executable, args...))
}

func (readiness *encoderReadiness) check() error {
	readiness.mutex.Lock()
	defer readiness.mutex.Unlock()

	if !readiness.checkedAt.IsZero() && time.Since(readiness.checkedAt) < readiness.cacheTTL {
		return readiness.err
	}

	readiness.checkedAt = time.Now()
	readiness.err = nil
	probeContext, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	output, err := readiness.run(probeContext, ffmpegExecutable, "-version")
	cancel()
	if err != nil {
		details := strings.TrimSpace(string(output))
		if len(details) > 2_000 {
			details = details[len(details)-2_000:]
		}
		readiness.err = fmt.Errorf("ffmpeg probe failed: %w: %s", err, details)
		return readiness.err
	}

	if readiness.backend != "nvenc" {
		return nil
	}

	for _, encoder := range []string{"h264_nvenc", "hevc_nvenc", "av1_nvenc"} {
		probeContext, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		output, err := readiness.run(
			probeContext,
			ffmpegExecutable,
			"-hide_banner", "-loglevel", "error",
			"-f", "lavfi", "-i", "color=size=256x256:rate=1",
			"-frames:v", "1", "-c:v", encoder, "-f", "null", "-",
		)
		cancel()
		if err != nil {
			details := strings.TrimSpace(string(output))
			if len(details) > 2_000 {
				details = details[len(details)-2_000:]
			}
			readiness.err = fmt.Errorf("%s probe failed: %w: %s", encoder, err, details)
			break
		}
	}

	return readiness.err
}

func healthHandler(instanceID string, readiness *encoderReadiness, tracker *activityTracker) http.HandlerFunc {
	return func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set(instanceHeader, instanceID)
		accepting, active := tracker.status()
		if !accepting {
			sendJSON(writer, http.StatusServiceUnavailable, map[string]string{"status": "draining"})
			return
		}
		// FFmpeg is already known to be runnable once an encode has been accepted.
		// Keep platform liveness probes cheap while it is consuming the instance's
		// CPU; spawning another FFmpeg process can exceed the probe deadline and
		// cause a healthy long-running encode to be terminated.
		if active == 0 {
			if err := readiness.check(); err != nil {
				log.Printf("encoder-readiness-error: %v", err)
				sendJSON(writer, http.StatusServiceUnavailable, map[string]string{"status": "unavailable"})
				return
			}
		}
		if !holdWarmupRequest(request) {
			return
		}
		sendJSON(writer, http.StatusOK, map[string]string{"status": "ok"})
	}
}

func holdWarmupRequest(request *http.Request) bool {
	holdMilliseconds, err := strconv.Atoi(request.URL.Query().Get("hold_ms"))
	if err != nil || holdMilliseconds <= 0 {
		return true
	}

	hold := time.Duration(holdMilliseconds) * time.Millisecond
	if hold > maxWarmupHold {
		hold = maxWarmupHold
	}

	timer := time.NewTimer(hold)
	defer timer.Stop()

	select {
	case <-timer.C:
		return true
	case <-request.Context().Done():
		return false
	}
}

func (recent *recentLog) add(line string) {
	recent.mutex.Lock()
	defer recent.mutex.Unlock()
	if len(recent.lines) == 20 {
		recent.lines = recent.lines[1:]
	}
	recent.lines = append(recent.lines, line)
}

func (recent *recentLog) string() string {
	recent.mutex.Lock()
	defer recent.mutex.Unlock()
	return strings.Join(recent.lines, "\n")
}

func (recent *recentLog) setProgress(progress map[string]string) {
	recent.mutex.Lock()
	defer recent.mutex.Unlock()
	recent.progress = make(map[string]string, len(progress))
	for key, value := range progress {
		recent.progress[key] = value
	}
}

func (recent *recentLog) progressSnapshot() map[string]string {
	recent.mutex.Lock()
	defer recent.mutex.Unlock()
	snapshot := make(map[string]string, len(recent.progress))
	for key, value := range recent.progress {
		snapshot[key] = value
	}
	return snapshot
}

func validateCompletedAudioOutput(request encodeRequest, metrics map[string]string) error {
	if request.Operation != "audio" {
		return nil
	}
	outTime, err := strconv.ParseInt(strings.TrimSpace(metrics["out_time_ms"]), 10, 64)
	if err != nil || outTime <= 0 {
		return errors.New("ffmpeg produced no audio frames")
	}
	return nil
}

func readProgress(stream io.Reader, inputURL string, inputBasicAuth string, recent *recentLog) {
	readProgressWithInputs(stream, ffmpegSourceRedactions(inputURL, inputBasicAuth), recent)
}

func readProgressWithInputs(stream io.Reader, inputURLs []string, recent *recentLog) {
	scanner := bufio.NewScanner(stream)
	scanner.Buffer(make([]byte, 4096), 1024*1024)
	progress := make(map[string]string)
	for scanner.Scan() {
		line := scanner.Text()
		for _, inputURL := range inputURLs {
			if inputURL != "" {
				line = strings.ReplaceAll(line, inputURL, "<input-url>")
			}
		}
		if line == "" {
			continue
		}
		recent.add(line)
		key, value, found := strings.Cut(line, "=")
		if found && !strings.HasPrefix(line, "[") {
			progress[key] = value
			if key == "progress" {
				recent.setProgress(progress)
				encoded, _ := json.Marshal(map[string]string{
					"event": "ffmpeg-progress", "frame": progress["frame"],
					"out_time": progress["out_time"], "speed": progress["speed"], "state": value,
				})
				log.Print(string(encoded))
				clear(progress)
			}
		} else {
			log.Printf("ffmpeg: %s", line)
		}
	}
}

func declareFFmpegTrailers(writer http.ResponseWriter) {
	writer.Header().Add("Trailer", "X-Mave-FFmpeg-Elapsed-Ms")
	for _, header := range ffmpegMetricHeaders {
		writer.Header().Add("Trailer", header)
	}
}

func setFFmpegTrailers(writer http.ResponseWriter, startedAt time.Time, recent *recentLog) {
	writer.Header().Set("X-Mave-FFmpeg-Elapsed-Ms", strconv.FormatInt(time.Since(startedAt).Milliseconds(), 10))
	progress := recent.progressSnapshot()
	for field, header := range ffmpegMetricHeaders {
		if value := strings.TrimSpace(progress[field]); value != "" && value != "N/A" {
			writer.Header().Set(header, value)
		}
	}
}

func streamToMultipartUpload(
	ctx context.Context,
	writer http.ResponseWriter,
	reader io.Reader,
	upload multipartUpload,
) (int64, []uploadedPart, error) {
	return streamToMultipartUploadWithHeartbeat(
		ctx,
		writer,
		reader,
		upload,
		multipartHeartbeatInterval,
	)
}

func streamToMultipartUploadWithHeartbeat(
	ctx context.Context,
	writer http.ResponseWriter,
	reader io.Reader,
	upload multipartUpload,
	heartbeatInterval time.Duration,
) (int64, []uploadedPart, error) {
	encoder, flusher, err := startMultipartResponse(writer)
	if err != nil {
		return 0, nil, err
	}

	return streamToMultipartUploadWithEvents(
		ctx,
		reader,
		upload,
		encoder,
		flusher,
		heartbeatInterval,
	)
}

func startMultipartResponse(writer http.ResponseWriter) (*json.Encoder, http.Flusher, error) {
	writer.Header().Set("Content-Type", "application/x-ndjson")
	writer.Header().Set("Cache-Control", "no-store")
	writer.WriteHeader(http.StatusOK)
	flusher, _ := writer.(http.Flusher)
	encoder := json.NewEncoder(writer)
	if err := writeUploadEvent(encoder, flusher, uploadEvent{Status: "started"}); err != nil {
		return nil, nil, err
	}
	return encoder, flusher, nil
}

func streamToMultipartUploadWithEvents(
	ctx context.Context,
	reader io.Reader,
	upload multipartUpload,
	encoder *json.Encoder,
	flusher http.Flusher,
	heartbeatInterval time.Duration,
) (int64, []uploadedPart, error) {
	parts := make([]uploadedPart, 0, len(upload.PartURLs))
	buffer := make([]byte, upload.PartSizeBytes)
	var uploadedBytes int64

	for partIndex, partURL := range upload.PartURLs {
		bytesRead, readErr := readMultipartPartWithHeartbeat(
			ctx,
			reader,
			buffer,
			encoder,
			flusher,
			uploadedBytes,
			heartbeatInterval,
		)
		if bytesRead == 0 && errors.Is(readErr, io.EOF) {
			break
		}
		if readErr != nil && !errors.Is(readErr, io.ErrUnexpectedEOF) && !errors.Is(readErr, io.EOF) {
			abortMultipartUploadBestEffort(upload.AbortURL)
			return uploadedBytes, parts, readErr
		}

		etag, err := uploadMultipartPartWithHeartbeat(
			ctx,
			partURL,
			buffer[:bytesRead],
			encoder,
			flusher,
			uploadedBytes,
			heartbeatInterval,
		)
		if err != nil {
			abortMultipartUploadBestEffort(upload.AbortURL)
			return uploadedBytes, parts, err
		}

		partNumber := partIndex + 1
		parts = append(parts, uploadedPart{PartNumber: partNumber, ETag: etag})
		uploadedBytes += int64(bytesRead)
		if err := writeUploadEvent(encoder, flusher, uploadEvent{
			Status:        "uploading",
			UploadedBytes: uploadedBytes,
			PartNumber:    partNumber,
		}); err != nil {
			abortMultipartUploadBestEffort(upload.AbortURL)
			return uploadedBytes, parts, err
		}

		if errors.Is(readErr, io.ErrUnexpectedEOF) || errors.Is(readErr, io.EOF) {
			break
		}
	}

	if len(parts) == len(upload.PartURLs) {
		probe := make([]byte, 1)
		bytesRead, err := readMultipartPartWithHeartbeat(
			ctx,
			reader,
			probe,
			encoder,
			flusher,
			uploadedBytes,
			heartbeatInterval,
		)
		if bytesRead > 0 || (err != nil && !errors.Is(err, io.EOF)) {
			abortMultipartUploadBestEffort(upload.AbortURL)
			return uploadedBytes, parts, errors.New("encoded output exceeded multipart capacity")
		}
	}
	if len(parts) == 0 {
		abortMultipartUploadBestEffort(upload.AbortURL)
		return 0, parts, errors.New("encoded output was empty")
	}

	return uploadedBytes, parts, nil
}

type multipartReadResult struct {
	bytesRead int
	err       error
}

type multipartUploadPartResult struct {
	etag string
	err  error
}

func readMultipartPartWithHeartbeat(
	ctx context.Context,
	reader io.Reader,
	buffer []byte,
	encoder *json.Encoder,
	flusher http.Flusher,
	uploadedBytes int64,
	heartbeatInterval time.Duration,
) (int, error) {
	if heartbeatInterval <= 0 {
		return io.ReadFull(reader, buffer)
	}

	result := make(chan multipartReadResult, 1)
	go func() {
		bytesRead, err := io.ReadFull(reader, buffer)
		result <- multipartReadResult{bytesRead: bytesRead, err: err}
	}()

	ticker := time.NewTicker(heartbeatInterval)
	defer ticker.Stop()

	for {
		select {
		case readResult := <-result:
			return readResult.bytesRead, readResult.err

		case <-ticker.C:
			if err := writeUploadEvent(encoder, flusher, uploadEvent{
				Status:        "uploading",
				UploadedBytes: uploadedBytes,
			}); err != nil {
				return 0, err
			}

		case <-ctx.Done():
			return 0, ctx.Err()
		}
	}
}

func uploadMultipartPartWithHeartbeat(
	ctx context.Context,
	partURL string,
	body []byte,
	encoder *json.Encoder,
	flusher http.Flusher,
	uploadedBytes int64,
	heartbeatInterval time.Duration,
) (string, error) {
	if heartbeatInterval <= 0 {
		return uploadMultipartPart(ctx, partURL, body)
	}

	result := make(chan multipartUploadPartResult, 1)
	go func() {
		etag, err := uploadMultipartPart(ctx, partURL, body)
		result <- multipartUploadPartResult{etag: etag, err: err}
	}()

	ticker := time.NewTicker(heartbeatInterval)
	defer ticker.Stop()

	for {
		select {
		case uploadResult := <-result:
			return uploadResult.etag, uploadResult.err

		case <-ticker.C:
			if err := writeUploadEvent(encoder, flusher, uploadEvent{
				Status:        "uploading",
				UploadedBytes: uploadedBytes,
			}); err != nil {
				return "", err
			}

		case <-ctx.Done():
			return "", ctx.Err()
		}
	}
}

func writeUploadEvent(encoder *json.Encoder, flusher http.Flusher, event uploadEvent) error {
	if err := encoder.Encode(event); err != nil {
		return err
	}
	if flusher != nil {
		flusher.Flush()
	}
	return nil
}

func uploadMultipartPart(ctx context.Context, partURL string, body []byte) (string, error) {
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		request, err := http.NewRequestWithContext(ctx, http.MethodPut, partURL, bytes.NewReader(body))
		if err != nil {
			return "", errors.New("could not create multipart part request")
		}
		request.ContentLength = int64(len(body))
		response, err := doStorageRequest(request)
		if err == nil && response != nil {
			_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 8*1024))
			_ = response.Body.Close()
			if response.StatusCode >= 200 && response.StatusCode <= 299 {
				etag := strings.TrimSpace(response.Header.Get("ETag"))
				if etag == "" {
					return "", errors.New("multipart upload response did not include an ETag")
				}
				return etag, nil
			}
			lastErr = fmt.Errorf("multipart part upload returned HTTP %d", response.StatusCode)
		} else if err != nil {
			lastErr = errors.New("multipart part upload request failed")
		}
		if attempt < 2 {
			select {
			case <-ctx.Done():
				return "", ctx.Err()
			case <-time.After(time.Duration(attempt+1) * 500 * time.Millisecond):
			}
		}
	}
	return "", lastErr
}

type completeMultipartUploadDocument struct {
	XMLName xml.Name                      `xml:"CompleteMultipartUpload"`
	Parts   []completeMultipartUploadPart `xml:"Part"`
}

type completeMultipartUploadPart struct {
	PartNumber int    `xml:"PartNumber"`
	ETag       string `xml:"ETag"`
}

func completeMultipartUpload(ctx context.Context, completeURL string, parts []uploadedPart) error {
	document := completeMultipartUploadDocument{Parts: make([]completeMultipartUploadPart, 0, len(parts))}
	for _, part := range parts {
		document.Parts = append(document.Parts, completeMultipartUploadPart{
			PartNumber: part.PartNumber,
			ETag:       part.ETag,
		})
	}
	body, err := xml.Marshal(document)
	if err != nil {
		return err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, completeURL, bytes.NewReader(body))
	if err != nil {
		return errors.New("could not create multipart completion request")
	}
	request.Header.Set("Content-Type", "application/xml")
	request.ContentLength = int64(len(body))
	response, err := doStorageRequest(request)
	if err != nil {
		return errors.New("multipart completion request failed")
	}
	defer response.Body.Close()
	responseBody, _ := io.ReadAll(io.LimitReader(response.Body, 64*1024))
	if response.StatusCode < 200 || response.StatusCode > 299 {
		return fmt.Errorf("multipart completion returned HTTP %d", response.StatusCode)
	}
	if bytes.Contains(responseBody, []byte("<Error>")) {
		return errors.New("multipart completion returned an object-storage error")
	}
	return nil
}

func abortMultipartUpload(ctx context.Context, abortURL string) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodDelete, abortURL, nil)
	if err != nil {
		return errors.New("could not create multipart abort request")
	}
	response, err := doStorageRequest(request)
	if err != nil {
		return errors.New("multipart abort request failed")
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 8*1024))
	if (response.StatusCode < 200 || response.StatusCode > 299) && response.StatusCode != http.StatusNotFound {
		return fmt.Errorf("multipart abort returned HTTP %d", response.StatusCode)
	}
	return nil
}

func abortMultipartUploadBestEffort(abortURL string) {
	abortContext, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := abortMultipartUpload(abortContext, abortURL); err != nil {
		log.Printf("multipart-abort-error: %v", err)
	}
}

func doStorageRequest(request *http.Request) (*http.Response, error) {
	client := *http.DefaultClient
	client.CheckRedirect = func(_request *http.Request, _via []*http.Request) error {
		return http.ErrUseLastResponse
	}
	return client.Do(request)
}

func ffmpegArgs(request encodeRequest, backend string) []string {
	switch request.Operation {
	case "audio":
		return audioFFmpegArgs(request)
	case "audio_peaks":
		return audioPeaksFFmpegArgs(request)
	case "frame":
		return frameFFmpegArgs(request)
	case "waveform":
		return waveformFFmpegArgs(request)
	case "storyboard":
		return storyboardFFmpegArgs(request)
	default:
		return videoFFmpegArgs(request, backend)
	}
}

// Keep this filter aligned with MediaGenerateAudioPeaksStep's FLAME fallback.
// Separate channels preserve peaks in opposite-phase stereo; output is at most 512 buckets.
func audioPeaksFFmpegArgs(request encodeRequest) []string {
	samples := int64(math.Ceil(request.DurationSeconds * 48000 / 512))
	filter := fmt.Sprintf("aresample=48000,asetnsamples=n=%d:p=0,astats=metadata=1:reset=1:measure_perchannel=none:measure_overall=Peak_level,ametadata=mode=print:key=lavfi.astats.Overall.Peak_level:file='pipe\\:1'", samples)
	args := append(ffmpegBaseArgs(request), "-i", request.InputURL,
		"-t", strconv.FormatFloat(request.DurationSeconds, 'f', -1, 64),
		"-map", "0:a:0", "-vn", "-af", filter, "-f", "null", "-")
	return args
}

func ffmpegArgsForOutput(request encodeRequest, backend string, outputPath string) []string {
	args := ffmpegArgs(request, backend)
	if outputPath != "" && len(args) > 0 && args[len(args)-1] == "pipe:1" {
		args[len(args)-1] = outputPath
	}
	return args
}

func requiresSeekableFrameOutput(request encodeRequest) bool {
	return request.Operation == "frame" && request.FrameCodec == "avif"
}

func ffmpegBaseArgs(request encodeRequest) []string {
	inputFormats := safeInputFormats
	if request.Operation == "frame" {
		// Frames also accept generated JPEGs and uploaded JPG/PNG posters.
		inputFormats = safeFrameInputFormats
	}
	args := []string{
		"-hide_banner", "-nostdin", "-y", "-loglevel", "warning",
		"-progress", "pipe:2", "-stats_period", "0.5", "-nostats",
		"-format_whitelist", inputFormats,
	}
	if headers := ffmpegSourceHeaders(request.InputReferer, request.InputBasicAuth); headers != "" {
		args = append(args, "-headers", headers)
	}
	if request.StartSeconds > 0 {
		args = append(args, "-ss", strconv.FormatFloat(request.StartSeconds, 'f', 3, 64))
	}
	return args
}

func ffmpegSourceHeaders(inputReferer string, inputBasicAuth string) string {
	var headers strings.Builder
	if inputReferer != "" {
		headers.WriteString("Referer: ")
		headers.WriteString(inputReferer)
		headers.WriteString("\r\n")
	}
	if inputBasicAuth != "" {
		headers.WriteString("Authorization: Basic ")
		headers.WriteString(base64.StdEncoding.EncodeToString([]byte(inputBasicAuth)))
		headers.WriteString("\r\n")
	}
	return headers.String()
}

func videoFFmpegArgs(request encodeRequest, backend string) []string {
	args := append(ffmpegBaseArgs(request),
		// Never publish a partial rendition after a source/demux/decode error.
		"-xerror", "-abort_on", "empty_output",
		"-i", request.InputURL,
		"-map_metadata", "-1", "-map", "0:v:0",
		"-vf", fmt.Sprintf(
			"scale=iw*sar:ih,setsar=1,scale=w=%d:h=%d:force_original_aspect_ratio=decrease:force_divisible_by=2",
			request.Width,
			request.Width,
		),
		"-c:v", videoEncoder(request.Codec, backend), "-preset", encoderPreset(request.Codec, request.Preset, backend),
	)
	if backend == "cpu" && request.Codec != "av1" && request.Tune != "" {
		args = append(args, "-tune", request.Tune)
	}
	if request.VideoBitrate != "" {
		args = append(args, "-b:v", request.VideoBitrate)
	}
	if request.VideoCRF > 0 {
		qualityOption := "-crf"
		if backend == "nvenc" {
			qualityOption = "-cq"
		}
		args = append(args, qualityOption, strconv.Itoa(request.VideoCRF))
	}
	if backend == "cpu" && request.SVTAV1Params != "" {
		args = append(args, "-svtav1-params", request.SVTAV1Params)
	}
	args = append(args, "-pix_fmt", "yuv420p", "-threads", "0")
	if request.KeyframeIntervalSeconds > 0 {
		args = append(args, "-force_key_frames", fmt.Sprintf("expr:gte(t,n_forced*%d)", request.KeyframeIntervalSeconds))
	}
	if request.GOPFrames > 0 {
		args = append(args, "-g", strconv.Itoa(request.GOPFrames))
	}
	if request.IncludeAudio == nil || *request.IncludeAudio {
		args = append(args, "-map", "0:a?", "-c:a", "aac", "-b:a", request.AudioBitrate)
	} else {
		args = append(args, "-an")
	}
	if request.DurationSeconds > 0 {
		args = append(args, "-t", strconv.FormatFloat(request.DurationSeconds, 'f', 3, 64))
	} else if request.MaxDurationSeconds > 0 {
		args = append(args, "-t", strconv.Itoa(request.MaxDurationSeconds))
	}
	if request.Codec == "hevc" {
		args = append(args, "-tag:v", "hvc1")
	} else if request.Codec == "av1" {
		args = append(args, "-tag:v", "av01")
	}
	return append(args,
		"-movflags", "frag_keyframe+empty_moov+default_base_moof",
		"-f", "mp4", "pipe:1",
	)
}

func audioFFmpegArgs(request encodeRequest) []string {
	args := append(ffmpegBaseArgs(request),
		"-i", request.InputURL,
		"-map_metadata", "-1",
		"-map", fmt.Sprintf("0:a:%d", request.AudioStreamIndex),
	)

	switch request.AudioCodec {
	case "aac":
		return append(args,
			"-codec:a", "aac", "-b:a", request.AudioBitrate,
			"-movflags", "frag_keyframe+empty_moov+default_base_moof",
			"-f", "mp4", "pipe:1",
		)
	case "wav":
		return append(args, "-c:a", "pcm_s16le", "-rf64", "auto", "-f", "wav", "pipe:1")
	case "opus":
		return append(args, "-c:a", "libopus", "-b:a", request.AudioBitrate, "-f", "ogg", "pipe:1")
	default:
		return append(args, "-codec:a", "libmp3lame", "-b:a", request.AudioBitrate, "-f", "mp3", "pipe:1")
	}
}

func frameFFmpegArgs(request encodeRequest) []string {
	args := ffmpegBaseArgs(request)
	if inputFormat := frameImageInputFormat(request.InputURL); inputFormat != "" {
		args = append(args, "-f", inputFormat)
	}
	args = append(args, "-i", request.InputURL)
	codec, format := frameEncoderAndFormat(request.FrameCodec)

	switch request.FrameRole {
	case "poster":
		args = append(args,
			"-map_metadata", "-1", "-c:v", codec,
			"-vf", framePosterFilter(request.FrameCodec), "-frames:v", "1",
		)
		args = append(args, frameQualityArgs(request.FrameCodec)...)
	case "thumbnail", "custom_thumbnail":
		args = append(args,
			"-map_metadata", "-1", "-c:v", codec, "-frames:v", "1",
			"-vf", "scale=iw*sar:ih,setsar=1,scale=w=1280:h=1280:force_original_aspect_ratio=decrease:force_divisible_by=2",
		)
		args = append(args, frameQualityArgs(request.FrameCodec)...)
	case "segment":
		args = append(args,
			"-map_metadata", "-1", "-c:v", codec, "-frames:v", "1",
			"-vf", "scale=iw*sar:ih,setsar=1,scale=w=1280:h=1280:force_original_aspect_ratio=decrease:force_divisible_by=2",
		)
		args = append(args, storyboardQualityArgs(request.FrameCodec)...)
	case "placeholder":
		args = append(args,
			"-i", placeholderOverlayPath(),
			"-map_metadata", "-1",
			"-filter_complex", "[1:v]scale=iw*0.15:-1[logo];[0:v][logo]overlay=(main_w-overlay_w)/2:(main_h-overlay_h)/2",
			"-frames:v", "1", "-c:v", codec,
		)
		args = append(args, placeholderQualityArgs(request.FrameCodec)...)
	default:
		args = append(args, "-map_metadata", "-1", "-frames:v", "1", "-c:v", codec)
		args = append(args, frameQualityArgs(request.FrameCodec)...)
	}

	return append(args, "-f", format, "pipe:1")
}

func frameImageInputFormat(inputURL string) string {
	parsed, err := url.Parse(inputURL)
	if err != nil {
		return ""
	}
	// Use a single-image demuxer even when probing would prefer image2 sequences.
	switch strings.ToLower(filepath.Ext(parsed.Path)) {
	case ".jpg", ".jpeg":
		return "jpeg_pipe"
	case ".png":
		return "png_pipe"
	default:
		return ""
	}
}

// Keep this graph aligned with MediaTranscodeWaveformStep's fallback renderer.
// Fixed frequency bands react to the current audio; circular tips become dots
// during silence. Supersampling keeps the edges smooth.
// showfreqs averaging > 1 divides by zero at y=0 and latches that band at full height.
// Its overlapping FFT windows already provide a short analysis window at 30 fps.
const waveformFilterGraph = "[0:a:0]aresample=48000,aformat=channel_layouts=mono,volume=3," +
	"showfreqs=s=64x160:r=30:mode=bar:fscale=log:ascale=cbrt:" +
	"win_size=2048:averaging=1:colors=white," +
	"setparams=range=full:color_primaries=bt709:color_trc=bt709:colorspace=gbr," +
	"scale=out_color_matrix=bt709:out_range=tv,format=yuv444p," +
	"drawbox=x=0:y=ih-1:w=iw:h=1:color=white:t=fill,scale=1024:160:flags=neighbor," +
	"geq=lum='if(lt(abs(mod(X,16)-7.5),4)," +
	"lum(X,Y+sqrt(16-pow(mod(X,16)-7.5,2))-1),16)':cb=128:cr=128," +
	"split[top][bottom];[bottom]vflip[mirror];[top][mirror]vstack," +
	"pad=1280:720:128:200:black,scale=640:360:flags=area,setsar=1,format=yuv420p," +
	"setpts=PTS-STARTPTS[v]"

func waveformFFmpegArgs(request encodeRequest) []string {
	// Warm up the FFT at chunk boundaries.
	warmupSeconds := min(request.StartSeconds, 0.2)
	request.StartSeconds -= warmupSeconds
	filter := waveformFilterGraph
	if warmupSeconds > 0 {
		filter = strings.TrimSuffix(filter, "[v]") + fmt.Sprintf(
			",trim=start=%.6f,setpts=PTS-STARTPTS[v]", warmupSeconds,
		)
	}
	args := append(ffmpegBaseArgs(request),
		"-i", request.InputURL,
	)
	if request.DurationSeconds > 0 {
		args = append(args, "-t", strconv.FormatFloat(request.DurationSeconds, 'f', 3, 64))
	}
	args = append(args, "-map_metadata", "-1",
		"-filter_complex", filter,
		"-map", "[v]", "-c:v", "libx264", "-threads", "0",
	)
	if request.IncludeAudio != nil && *request.IncludeAudio {
		args = append(args, "-map", "0:a:0", "-c:a", "aac", "-b:a", "128k")
		if warmupSeconds > 0 {
			args = append(args, "-af", fmt.Sprintf("atrim=start=%.6f,asetpts=PTS-STARTPTS", warmupSeconds))
		}
	} else {
		args = append(args, "-an")
	}
	return append(args,
		"-movflags", "frag_keyframe+empty_moov+default_base_moof",
		"-f", "mp4", "pipe:1",
	)
}

func storyboardFFmpegArgs(request encodeRequest) []string {
	columns := min(request.Count, 10)
	rows := max((request.Count+columns-1)/columns, 1)
	interval := max(request.DurationSeconds/float64(request.Count), 1.0)
	codec, format := frameEncoderAndFormat(request.FrameCodec)
	filter := fmt.Sprintf(
		"fps=1/%.3f,scale=320:-2,setsar=1,tile=%dx%d",
		interval, columns, rows,
	)
	args := append(ffmpegBaseArgs(request),
		"-i", request.InputURL, "-map_metadata", "-1", "-vf", filter,
		"-frames:v", "1", "-c:v", codec,
	)
	args = append(args, storyboardQualityArgs(request.FrameCodec)...)
	return append(args, "-f", format, "pipe:1")
}

func frameEncoderAndFormat(codec string) (string, string) {
	switch codec {
	case "png":
		return "png", "image2pipe"
	case "webp":
		return "libwebp", "webp"
	case "avif":
		return "libsvtav1", "avif"
	default:
		return "mjpeg", "image2pipe"
	}
}

func framePosterFilter(codec string) string {
	if codec == "avif" {
		return "scale=trunc(iw*sar/2)*2:trunc(ih/2)*2,setsar=1"
	}
	return "scale=iw*sar:ih,setsar=1"
}

func frameQualityArgs(codec string) []string {
	switch codec {
	case "avif":
		return []string{"-crf", "55", "-svtav1-params", "avif=1"}
	case "webp":
		return []string{"-quality", "10"}
	case "jpg", "jpeg":
		return []string{"-strict", "unofficial", "-q:v", "6"}
	default:
		return nil
	}
}

func placeholderQualityArgs(codec string) []string {
	if codec == "jpg" || codec == "jpeg" {
		return []string{"-strict", "unofficial", "-q:v", "2"}
	}
	return frameQualityArgs(codec)
}

func storyboardQualityArgs(codec string) []string {
	if codec == "webp" {
		return []string{"-quality", "80"}
	}
	return frameQualityArgs(codec)
}

func concatFFmpegArgs(request concatRequest) []string {
	args := []string{
		"-hide_banner", "-nostdin", "-y", "-loglevel", "warning",
		// FFmpeg otherwise exits successfully even when a later chunk cannot be read.
		"-xerror", "-abort_on", "empty_output",
		"-progress", "pipe:2", "-stats_period", "0.5", "-nostats",
	}
	if request.InputReferer != "" {
		args = append(args, "-headers", "Referer: "+request.InputReferer+"\r\n")
	}
	return append(args,
		"-protocol_whitelist", "file,http,https,tcp,tls,crypto,pipe",
		"-f", "concat", "-safe", "0", "-i", "pipe:0",
		"-map", "0:v:0", "-map", "0:a?", "-c", "copy",
		"-movflags", "frag_keyframe+empty_moov+default_base_moof",
		"-f", "mp4", "pipe:1",
	)
}

func concatManifest(inputURLs []string) string {
	var manifest strings.Builder
	manifest.WriteString("ffconcat version 1.0\n")
	for _, inputURL := range inputURLs {
		manifest.WriteString("file '")
		manifest.WriteString(strings.ReplaceAll(inputURL, "'", "'\\''"))
		manifest.WriteString("'\n")
	}
	return manifest.String()
}

func hlsArgs(inputPath string, outputDir string) []string {
	return hlsArgsWithReferer(inputPath, outputDir, "", "")
}

func hlsArgsWithReferer(inputPath string, outputDir string, inputReferer string, inputBasicAuth string) []string {
	args := []string{
		"-hide_banner", "-nostdin", "-y", "-loglevel", "error",
		"-xerror", "-abort_on", "empty_output",
		"-format_whitelist", safeInputFormats,
	}
	args = append(args, hlsSourceRetryArgs(inputPath)...)
	if headers := ffmpegSourceHeaders(inputReferer, inputBasicAuth); headers != "" {
		args = append(args, "-headers", headers)
	}
	return append(args,
		"-i", inputPath,
		"-map", "0:v:0", "-c:v", "copy", "-an",
		"-hls_time", "6", "-hls_playlist_type", "vod",
		"-hls_flags", "independent_segments+temp_file",
		"-hls_segment_type", "fmp4",
		"-hls_fmp4_init_filename", "init.mp4",
		"-hls_segment_filename", filepath.Join(outputDir, "segment_%03d.m4s"),
		filepath.Join(outputDir, "playlist.m3u8"),
	)
}

func hlsAudioArgsWithReferer(inputPath string, outputDir string, inputReferer string, inputBasicAuth string, channels int) []string {
	args := []string{
		"-hide_banner", "-nostdin", "-y", "-loglevel", "error",
		"-xerror", "-abort_on", "empty_output",
		"-format_whitelist", safeInputFormats,
	}
	args = append(args, hlsSourceRetryArgs(inputPath)...)
	if headers := ffmpegSourceHeaders(inputReferer, inputBasicAuth); headers != "" {
		args = append(args, "-headers", headers)
	}
	return append(args,
		"-i", inputPath,
		"-map_metadata", "-1", "-map", "0:a:0",
		"-c:a", "aac", "-b:a", "128k", "-ac", strconv.Itoa(channels),
		"-hls_time", "6", "-hls_playlist_type", "vod",
		"-hls_flags", "temp_file",
		"-hls_segment_type", "fmp4",
		"-hls_fmp4_init_filename", "init.mp4",
		"-hls_segment_filename", filepath.Join(outputDir, "segment_%03d.m4s"),
		filepath.Join(outputDir, "playlist.m3u8"),
	)
}

func hlsSourceRetryArgs(inputPath string) []string {
	if !strings.HasPrefix(inputPath, "https://") && !strings.HasPrefix(inputPath, "http://") {
		return nil
	}
	// HLS can process large renditions without retaining the entire source on
	// scratch disk. Resume interrupted reads and bound transient HTTP retries.
	return []string{
		"-reconnect", "1", "-reconnect_streamed", "1",
		"-reconnect_on_network_error", "1", "-reconnect_on_http_error", "408,429,5xx",
		"-reconnect_max_retries", "3", "-reconnect_delay_max", "5",
		"-reconnect_delay_total_max", "15",
	}
}

func packageHLSArgs(request packageHLSRequest, outputDir string) []string {
	if request.MediaKind == "audio" {
		return hlsAudioArgsWithReferer(request.InputURL, outputDir, request.InputReferer, request.InputBasicAuth, request.Channels)
	}
	return hlsArgsWithReferer(request.InputURL, outputDir, request.InputReferer, request.InputBasicAuth)
}

func videoEncoder(codec string, backend string) string {
	if backend == "nvenc" {
		return map[string]string{"h264": "h264_nvenc", "hevc": "hevc_nvenc", "av1": "av1_nvenc"}[codec]
	}
	return map[string]string{"h264": "libx264", "hevc": "libx265", "av1": "libsvtav1"}[codec]
}

func encoderPreset(codec string, preset string, backend string) string {
	if backend != "nvenc" {
		if codec == "av1" {
			return map[string]string{
				"ultrafast": "12", "superfast": "11", "veryfast": "10", "faster": "9",
				"fast": "8", "medium": "7", "slow": "6", "slower": "5",
				"veryslow": "4", "placebo": "3",
			}[preset]
		}
		return preset
	}
	return map[string]string{
		"ultrafast": "p1", "superfast": "p1", "veryfast": "p2", "faster": "p3",
		"fast": "p3", "medium": "p4", "slow": "p5", "slower": "p6",
		"veryslow": "p7", "placebo": "p7",
	}[preset]
}

func authorized(httpRequest *http.Request, bearerToken string) bool {
	if bearerToken == "" {
		return true
	}
	provided := strings.TrimPrefix(httpRequest.Header.Get("Authorization"), "Bearer ")
	if provided == "" || len(provided) != len(bearerToken) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(provided), []byte(bearerToken)) == 1
}

func idleHandler(tracker *activityTracker, bearerToken string, minimum time.Duration) http.HandlerFunc {
	return func(writer http.ResponseWriter, httpRequest *http.Request) {
		if httpRequest.Method != http.MethodGet {
			sendJSON(writer, http.StatusMethodNotAllowed, map[string]string{"error": "only GET is allowed"})
			return
		}
		if !authorized(httpRequest, bearerToken) {
			sendJSON(writer, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}
		if !tracker.idleFor(minimum) {
			sendJSON(writer, http.StatusConflict, map[string]string{"status": "busy"})
			return
		}
		sendJSON(writer, http.StatusOK, map[string]string{"status": "idle"})
	}
}

func drainHandler(tracker *activityTracker, bearerToken string, minimum time.Duration) http.HandlerFunc {
	return func(writer http.ResponseWriter, httpRequest *http.Request) {
		if httpRequest.Method != http.MethodPost {
			sendJSON(writer, http.StatusMethodNotAllowed, map[string]string{"error": "only POST is allowed"})
			return
		}
		if !authorized(httpRequest, bearerToken) {
			sendJSON(writer, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}
		if !tracker.drainIfIdle(minimum) {
			sendJSON(writer, http.StatusConflict, map[string]string{"status": "busy"})
			return
		}
		sendJSON(writer, http.StatusOK, map[string]string{"status": "draining"})
	}
}

func resumeHandler(tracker *activityTracker, bearerToken string) http.HandlerFunc {
	return func(writer http.ResponseWriter, httpRequest *http.Request) {
		if httpRequest.Method != http.MethodPost {
			sendJSON(writer, http.StatusMethodNotAllowed, map[string]string{"error": "only POST is allowed"})
			return
		}
		if !authorized(httpRequest, bearerToken) {
			sendJSON(writer, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}
		tracker.resume()
		sendJSON(writer, http.StatusOK, map[string]string{"status": "ready"})
	}
}

func streamEncodingBundle(
	writer http.ResponseWriter,
	command *exec.Cmd,
	stdout io.Reader,
	firstChunk []byte,
	firstReadErr error,
	buffer []byte,
	encodeContext context.Context,
	cancel context.CancelFunc,
	recent *recentLog,
	commandStartedAt time.Time,
) {
	tempDir, err := os.MkdirTemp(bundleTempDir(), "mave-encoding-bundle-")
	if err != nil {
		cancel()
		_ = command.Wait()
		sendJSON(writer, http.StatusInternalServerError, map[string]string{"error": "could not create bundle workspace"})
		return
	}
	defer os.RemoveAll(tempDir)

	mp4Path := filepath.Join(tempDir, "encoded.mp4")
	mp4File, err := os.OpenFile(mp4Path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		cancel()
		_ = command.Wait()
		sendJSON(writer, http.StatusInternalServerError, map[string]string{"error": "could not create bundle media"})
		return
	}

	writer.Header().Set("Content-Type", "application/vnd.mave.encoding-bundle+zip")
	writer.Header().Set("Content-Disposition", `attachment; filename="encoding-bundle.zip"`)
	writer.Header().Set("Cache-Control", "no-store")
	declareFFmpegTrailers(writer)
	writer.WriteHeader(http.StatusOK)

	zipWriter := zip.NewWriter(writer)
	mediaHeader := &zip.FileHeader{Name: "encoded.mp4", Method: zip.Store}
	mediaHeader.SetMode(0o600)
	mediaEntry, err := zipWriter.CreateHeader(mediaHeader)
	if err != nil {
		_ = mp4File.Close()
		cancel()
		_ = command.Wait()
		return
	}

	mediaOutput := io.MultiWriter(mediaEntry, mp4File)
	if _, err := mediaOutput.Write(firstChunk); err != nil {
		_ = mp4File.Close()
		cancel()
		_ = command.Wait()
		return
	}
	if flusher, ok := writer.(http.Flusher); ok {
		flusher.Flush()
	}
	if firstReadErr != nil && !errors.Is(firstReadErr, io.EOF) {
		log.Printf("stream-read-error: %v", firstReadErr)
		_ = mp4File.Close()
		cancel()
		_ = command.Wait()
		return
	}
	if _, err := io.CopyBuffer(mediaOutput, stdout, buffer); err != nil {
		log.Printf("bundle-stream-error: %v", err)
		_ = mp4File.Close()
		cancel()
		_ = command.Wait()
		return
	}
	if err := command.Wait(); err != nil {
		_ = mp4File.Close()
		if encodeContext.Err() == nil {
			log.Printf("ffmpeg-error: %v: %s", err, recent.string())
		}
		return
	}
	setFFmpegTrailers(writer, commandStartedAt, recent)
	if err := mp4File.Close(); err != nil {
		log.Printf("bundle-media-close-error: %v", err)
		return
	}

	hlsDir := filepath.Join(tempDir, "hls")
	if err := os.Mkdir(hlsDir, 0o700); err != nil {
		log.Printf("hls-directory-error: %v", err)
		return
	}
	packageOutput, err := mediaCommandOutput(mediaCommand(encodeContext, ffmpegExecutable, hlsArgs(mp4Path, hlsDir)...))
	if err != nil {
		details := strings.TrimSpace(string(packageOutput))
		if len(details) > 2_000 {
			details = details[len(details)-2_000:]
		}
		log.Printf("hls-package-error: %v: %s", err, details)
		return
	}

	entries, err := os.ReadDir(hlsDir)
	if err != nil {
		log.Printf("hls-read-error: %v", err)
		return
	}
	sort.Slice(entries, func(left int, right int) bool { return entries[left].Name() < entries[right].Name() })
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || (name != "init.mp4" && name != "playlist.m3u8" && !hlsFilePattern.MatchString(name)) {
			continue
		}
		if err := writeHLSZipEntry(zipWriter, hlsDir, name, buffer); err != nil {
			log.Printf("hls-entry-error: %s", name)
			return
		}
	}

	if err := zipWriter.Close(); err != nil {
		log.Printf("bundle-close-error: %v", err)
	}
}

func writeHLSBundle(writer http.ResponseWriter, hlsDir string) error {
	entries, err := os.ReadDir(hlsDir)
	if err != nil {
		return err
	}
	sort.Slice(entries, func(left int, right int) bool { return entries[left].Name() < entries[right].Name() })

	allowed := make([]os.DirEntry, 0, len(entries))
	hasPlaylist := false
	hasInit := false
	hasSegment := false
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || (name != "init.mp4" && name != "playlist.m3u8" && !hlsFilePattern.MatchString(name)) {
			continue
		}
		info, infoErr := statMediaOutput(filepath.Join(hlsDir, name))
		if infoErr != nil {
			return fmt.Errorf("inspect HLS entry %s: %w", name, infoErr)
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("invalid HLS entry %s", name)
		}
		allowed = append(allowed, entry)
		hasPlaylist = hasPlaylist || name == "playlist.m3u8"
		hasInit = hasInit || name == "init.mp4"
		hasSegment = hasSegment || hlsFilePattern.MatchString(name)
	}
	if !hasPlaylist || !hasInit || !hasSegment {
		return errors.New("incomplete HLS output")
	}

	writer.Header().Set("Content-Type", "application/vnd.mave.hls-bundle+zip")
	writer.Header().Set("Content-Disposition", `attachment; filename="hls-bundle.zip"`)
	writer.Header().Set("Cache-Control", "no-store")
	writer.WriteHeader(http.StatusOK)

	zipWriter := zip.NewWriter(writer)
	buffer := make([]byte, 64*1024)
	for _, entry := range allowed {
		name := entry.Name()
		if err := writeHLSZipEntry(zipWriter, hlsDir, name, buffer); err != nil {
			return err
		}
	}
	return zipWriter.Close()
}

func collectHLSFiles(hlsDir string) ([]hlsFile, error) {
	entries, err := os.ReadDir(hlsDir)
	if err != nil {
		return nil, err
	}
	sort.Slice(entries, func(left int, right int) bool { return entries[left].Name() < entries[right].Name() })

	files := make([]hlsFile, 0, len(entries))
	hasPlaylist := false
	hasInit := false
	hasSegment := false
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || (name != "init.mp4" && name != "playlist.m3u8" && !hlsFilePattern.MatchString(name)) {
			continue
		}
		info, infoErr := statMediaOutput(filepath.Join(hlsDir, name))
		if infoErr != nil {
			return nil, fmt.Errorf("inspect HLS entry %s: %w", name, infoErr)
		}
		if !info.Mode().IsRegular() || info.Size() <= 0 {
			return nil, fmt.Errorf("invalid HLS entry %s", name)
		}
		files = append(files, hlsFile{Name: name, SizeBytes: info.Size()})
		hasPlaylist = hasPlaylist || name == "playlist.m3u8"
		hasInit = hasInit || name == "init.mp4"
		hasSegment = hasSegment || hlsFilePattern.MatchString(name)
	}
	if !hasPlaylist || !hasInit || !hasSegment {
		return nil, errors.New("incomplete HLS output")
	}
	return files, nil
}

func requestHLSUploadTargets(
	ctx context.Context,
	callbackURL string,
	uploadToken string,
	files []hlsFile,
) ([]hlsUploadTarget, error) {
	parsed, err := url.ParseRequestURI(callbackURL)
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" || parsed.User != nil {
		return nil, errors.New("HLS upload callback is not configured")
	}
	payload, err := json.Marshal(hlsUploadRequest{Files: files})
	if err != nil {
		return nil, errors.New("could not encode HLS upload request")
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, callbackURL, bytes.NewReader(payload))
	if err != nil {
		return nil, errors.New("could not create HLS upload request")
	}
	request.Header.Set("Authorization", "Bearer "+uploadToken)
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json")
	request.ContentLength = int64(len(payload))

	response, err := doStorageRequest(request)
	if err != nil {
		return nil, errors.New("HLS upload authorization request failed")
	}
	defer response.Body.Close()
	responseBody, readErr := io.ReadAll(io.LimitReader(response.Body, 32*1024*1024))
	if readErr != nil {
		return nil, errors.New("could not read HLS upload authorization")
	}
	if response.StatusCode < 200 || response.StatusCode > 299 {
		return nil, fmt.Errorf("HLS upload authorization returned HTTP %d", response.StatusCode)
	}
	var uploadResponse hlsUploadResponse
	if err := json.Unmarshal(responseBody, &uploadResponse); err != nil {
		return nil, errors.New("invalid HLS upload authorization response")
	}
	if err := validateHLSUploadTargets(files, uploadResponse.Uploads); err != nil {
		return nil, err
	}
	return uploadResponse.Uploads, nil
}

func validateHLSUploadTargets(files []hlsFile, targets []hlsUploadTarget) error {
	if len(files) == 0 || len(targets) != len(files) {
		return errors.New("incomplete HLS upload authorization")
	}
	expected := make(map[string]int64, len(files))
	for _, file := range files {
		expected[file.Name] = file.SizeBytes
	}
	seen := make(map[string]bool, len(targets))
	for _, target := range targets {
		expectedSize, ok := expected[target.Name]
		if !ok || seen[target.Name] || expectedSize != target.SizeBytes || target.Key == "" || target.ContentType == "" {
			return errors.New("invalid HLS upload authorization")
		}
		parsed, err := url.ParseRequestURI(target.Upload.URL)
		if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" || parsed.User != nil {
			return errors.New("invalid HLS upload destination")
		}
		seen[target.Name] = true
	}
	return nil
}

type hlsUploadResult struct {
	Target hlsUploadTarget
	Err    error
}

type hlsFFmpegResult struct {
	Output []byte
	Err    error
}

func uploadHLSFiles(
	ctx context.Context,
	hlsDir string,
	targets []hlsUploadTarget,
	encoder *json.Encoder,
	flusher http.Flusher,
	uploadedBytesOffset int64,
	uploadedFilesOffset int,
) ([]hlsFile, int64, error) {
	uploadContext, cancel := context.WithCancel(ctx)
	defer cancel()

	jobs := make(chan hlsUploadTarget)
	results := make(chan hlsUploadResult)
	workerCount := 8
	if len(targets) < workerCount {
		workerCount = len(targets)
	}

	var workers sync.WaitGroup
	workers.Add(workerCount)
	for worker := 0; worker < workerCount; worker++ {
		go func() {
			defer workers.Done()
			for target := range jobs {
				err := uploadHLSFile(uploadContext, filepath.Join(hlsDir, target.Name), target)
				select {
				case results <- hlsUploadResult{Target: target, Err: err}:
				case <-uploadContext.Done():
					return
				}
				if err != nil {
					return
				}
			}
		}()
	}

	go func() {
		defer close(jobs)
		for _, target := range targets {
			select {
			case jobs <- target:
			case <-uploadContext.Done():
				return
			}
		}
	}()
	go func() {
		workers.Wait()
		close(results)
	}()

	uploaded := make([]hlsFile, 0, len(targets))
	uploadedBytes := uploadedBytesOffset
	for result := range results {
		if result.Err != nil {
			cancel()
			return nil, uploadedBytes, result.Err
		}
		target := result.Target
		uploaded = append(uploaded, hlsFile{
			Name: target.Name, Key: target.Key, ContentType: target.ContentType, SizeBytes: target.SizeBytes,
		})
		uploadedBytes += target.SizeBytes
		_ = encoder.Encode(hlsUploadEvent{
			Status: "uploading", UploadedBytes: uploadedBytes,
			FileCount: uploadedFilesOffset + len(uploaded),
		})
		if flusher != nil {
			flusher.Flush()
		}
	}
	if len(uploaded) != len(targets) {
		return nil, uploadedBytes, errors.New("incomplete HLS upload")
	}
	sort.Slice(uploaded, func(left int, right int) bool { return uploaded[left].Name < uploaded[right].Name })
	return uploaded, uploadedBytes, nil
}

func uploadHLSFile(ctx context.Context, path string, target hlsUploadTarget) error {
	file, err := openMediaOutput(path)
	if err != nil {
		return errors.New("could not open HLS output")
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || info.Size() != target.SizeBytes || info.Size() <= 0 {
		return errors.New("HLS output size changed")
	}
	// Keep the verified inode for retries, even if the encoder replaces its name.
	for attempt := 0; attempt < 3; attempt++ {
		body := io.NewSectionReader(file, 0, info.Size())
		request, err := http.NewRequestWithContext(ctx, http.MethodPut, target.Upload.URL, body)
		if err != nil {
			return errors.New("could not create HLS upload request")
		}
		request.ContentLength = target.SizeBytes
		for name, value := range target.Upload.Headers {
			if strings.ContainsAny(name+value, "\r\n") {
				return errors.New("invalid HLS upload header")
			}
			if strings.EqualFold(name, "content-length") {
				if value != strconv.FormatInt(target.SizeBytes, 10) {
					return errors.New("invalid HLS upload content length")
				}
				continue
			}
			request.Header.Set(name, value)
		}
		response, requestErr := doStorageRequest(request)
		if requestErr == nil && response != nil {
			_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 8*1024))
			_ = response.Body.Close()
			if response.StatusCode >= 200 && response.StatusCode <= 299 {
				return nil
			}
		}
		if attempt < 2 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(time.Duration(attempt+1) * 500 * time.Millisecond):
			}
		}
	}
	return errors.New("HLS object upload failed")
}

func collectPendingHLSSegments(hlsDir string, uploaded map[string]hlsFile) ([]hlsFile, error) {
	entries, err := os.ReadDir(hlsDir)
	if err != nil {
		return nil, err
	}
	sort.Slice(entries, func(left int, right int) bool { return entries[left].Name() < entries[right].Name() })

	files := make([]hlsFile, 0, len(entries))
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !hlsFilePattern.MatchString(name) {
			continue
		}
		if _, exists := uploaded[name]; exists {
			continue
		}
		info, infoErr := statMediaOutput(filepath.Join(hlsDir, name))
		if infoErr != nil {
			return nil, fmt.Errorf("inspect HLS entry %s: %w", name, infoErr)
		}
		if !info.Mode().IsRegular() || info.Size() <= 0 {
			return nil, fmt.Errorf("invalid HLS entry %s", name)
		}
		files = append(files, hlsFile{Name: name, SizeBytes: info.Size()})
	}
	return files, nil
}

func collectHLSControlFiles(hlsDir string) ([]hlsFile, error) {
	files := make([]hlsFile, 0, 2)
	for _, name := range []string{"init.mp4", "playlist.m3u8"} {
		info, err := statMediaOutput(filepath.Join(hlsDir, name))
		if err != nil {
			return nil, fmt.Errorf("inspect HLS entry %s: %w", name, err)
		}
		if !info.Mode().IsRegular() || info.Size() <= 0 {
			return nil, fmt.Errorf("invalid HLS entry %s", name)
		}
		files = append(files, hlsFile{Name: name, SizeBytes: info.Size()})
	}
	return files, nil
}

func uploadAndRemoveHLSFiles(
	ctx context.Context,
	hlsDir string,
	callbackURL string,
	uploadToken string,
	files []hlsFile,
	uploaded map[string]hlsFile,
	uploadedBytes int64,
	encoder *json.Encoder,
	flusher http.Flusher,
) (int64, error) {
	if len(files) == 0 {
		return uploadedBytes, nil
	}
	targets, err := requestHLSUploadTargets(ctx, callbackURL, uploadToken, files)
	if err != nil {
		return uploadedBytes, err
	}
	metadata, totalUploadedBytes, err := uploadHLSFiles(
		ctx,
		hlsDir,
		targets,
		encoder,
		flusher,
		uploadedBytes,
		len(uploaded),
	)
	if err != nil {
		return totalUploadedBytes, err
	}
	for _, file := range metadata {
		uploaded[file.Name] = file
		if err := os.Remove(filepath.Join(hlsDir, file.Name)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return totalUploadedBytes, fmt.Errorf("remove uploaded HLS entry %s: %w", file.Name, err)
		}
	}
	return totalUploadedBytes, nil
}

func uploadedHLSMetadata(uploaded map[string]hlsFile) ([]hlsFile, error) {
	files := make([]hlsFile, 0, len(uploaded))
	hasPlaylist := false
	hasInit := false
	hasSegment := false
	for _, file := range uploaded {
		files = append(files, file)
		hasPlaylist = hasPlaylist || file.Name == "playlist.m3u8"
		hasInit = hasInit || file.Name == "init.mp4"
		hasSegment = hasSegment || hlsFilePattern.MatchString(file.Name)
	}
	if !hasPlaylist || !hasInit || !hasSegment {
		return nil, errors.New("incomplete HLS output")
	}
	sort.Slice(files, func(left int, right int) bool { return files[left].Name < files[right].Name })
	return files, nil
}

func streamHLSToStorage(
	ctx context.Context,
	writer http.ResponseWriter,
	request packageHLSRequest,
	hlsDir string,
	callbackURL string,
	startedAt time.Time,
) {
	writer.Header().Set("Content-Type", "application/x-ndjson")
	writer.Header().Set("Cache-Control", "no-store")
	writer.WriteHeader(http.StatusOK)
	flusher, _ := writer.(http.Flusher)
	encoder := json.NewEncoder(writer)
	_ = encoder.Encode(hlsUploadEvent{Status: "packaging"})
	if flusher != nil {
		flusher.Flush()
	}

	ffmpegContext, cancelFFmpeg := context.WithCancel(ctx)
	defer cancelFFmpeg()
	resultChannel := make(chan hlsFFmpegResult, 1)
	go func() {
		output, err := mediaCommandOutput(mediaCommand(
			ffmpegContext,
			ffmpegExecutable,
			packageHLSArgs(request, hlsDir)...,
		))
		resultChannel <- hlsFFmpegResult{Output: output, Err: err}
	}()

	uploaded := make(map[string]hlsFile)
	var uploadedBytes int64
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()

	uploadSegments := func() error {
		files, err := collectPendingHLSSegments(hlsDir, uploaded)
		if err != nil {
			return err
		}
		uploadedBytes, err = uploadAndRemoveHLSFiles(
			ctx,
			hlsDir,
			callbackURL,
			request.UploadToken,
			files,
			uploaded,
			uploadedBytes,
			encoder,
			flusher,
		)
		return err
	}

	fail := func(message string) {
		_ = encoder.Encode(hlsUploadEvent{Status: "failed", Error: message})
		if flusher != nil {
			flusher.Flush()
		}
	}

	for {
		select {
		case <-ctx.Done():
			cancelFFmpeg()
			return

		case <-ticker.C:
			if err := uploadSegments(); err != nil {
				cancelFFmpeg()
				<-resultChannel
				log.Printf("hls-direct-upload-error: %v", err)
				fail("HLS object upload failed")
				return
			}

		case result := <-resultChannel:
			if result.Err != nil {
				details := sanitizedFFmpegDetails(
					string(result.Output),
					ffmpegSourceRedactions(request.InputURL, request.InputBasicAuth)...,
				)
				log.Printf("hls-package-error: %v: %s", result.Err, details)
				fail("could not package HLS: " + details)
				return
			}
			if err := uploadSegments(); err != nil {
				log.Printf("hls-direct-upload-error: %v", err)
				fail("HLS object upload failed")
				return
			}
			controlFiles, err := collectHLSControlFiles(hlsDir)
			if err != nil {
				log.Printf("hls-output-error: %v", err)
				fail("invalid HLS output")
				return
			}
			uploadedBytes, err = uploadAndRemoveHLSFiles(
				ctx,
				hlsDir,
				callbackURL,
				request.UploadToken,
				controlFiles,
				uploaded,
				uploadedBytes,
				encoder,
				flusher,
			)
			if err != nil {
				log.Printf("hls-direct-upload-error: %v", err)
				fail("HLS object upload failed")
				return
			}
			files, err := uploadedHLSMetadata(uploaded)
			if err != nil {
				log.Printf("hls-output-error: %v", err)
				fail("invalid HLS output")
				return
			}
			_ = encoder.Encode(hlsUploadEvent{
				Status: "completed", UploadedBytes: uploadedBytes, FileCount: len(files),
				FFmpegElapsedMS: time.Since(startedAt).Milliseconds(), Files: files,
			})
			if flusher != nil {
				flusher.Flush()
			}
			return
		}
	}
}

func packageHLSHandler(timeout time.Duration, instanceID string, bearerToken string, slots chan struct{}, tracker *activityTracker) http.HandlerFunc {
	return func(writer http.ResponseWriter, httpRequest *http.Request) {
		writer.Header().Set(instanceHeader, instanceID)
		if httpRequest.Method != http.MethodPost {
			sendJSON(writer, http.StatusMethodNotAllowed, map[string]string{"error": "only POST is allowed"})
			return
		}
		if !authorized(httpRequest, bearerToken) {
			sendJSON(writer, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}

		httpRequest.Body = http.MaxBytesReader(writer, httpRequest.Body, maxRequestBytes)
		decoder := json.NewDecoder(httpRequest.Body)
		decoder.DisallowUnknownFields()
		var request packageHLSRequest
		if err := decoder.Decode(&request); err != nil {
			sendJSON(writer, http.StatusBadRequest, map[string]string{"error": "invalid JSON: " + err.Error()})
			return
		}
		if err := request.validate(); err != nil {
			sendJSON(writer, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		uploadCallbackURL := strings.TrimSpace(os.Getenv("HLS_UPLOAD_CALLBACK_URL"))
		if request.UploadToken != "" {
			parsedCallback, callbackErr := url.ParseRequestURI(uploadCallbackURL)
			if callbackErr != nil || parsedCallback.Scheme != "https" || parsedCallback.Hostname() == "" || parsedCallback.User != nil {
				sendJSON(writer, http.StatusInternalServerError, map[string]string{"error": "HLS upload callback is not configured"})
				return
			}
		}
		if slots != nil {
			select {
			case slots <- struct{}{}:
				defer func() { <-slots }()
			default:
				sendJSON(writer, http.StatusTooManyRequests, map[string]string{"error": "busy"})
				return
			}
		}

		finishActivity, accepted := tracker.tryBegin()
		if !accepted {
			sendJSON(writer, http.StatusServiceUnavailable, map[string]string{"error": "draining"})
			return
		}
		defer finishActivity()

		packageContext, cancel := context.WithTimeout(httpRequest.Context(), timeout)
		defer cancel()
		tempDir, err := os.MkdirTemp(bundleTempDir(), "mave-hls-bundle-")
		if err != nil {
			sendJSON(writer, http.StatusInternalServerError, map[string]string{"error": "could not create HLS workspace"})
			return
		}
		defer os.RemoveAll(tempDir)

		hlsDir := filepath.Join(tempDir, "hls")
		if err := os.Mkdir(hlsDir, 0o700); err != nil {
			sendJSON(writer, http.StatusInternalServerError, map[string]string{"error": "could not create HLS directory"})
			return
		}
		startedAt := time.Now()
		if request.UploadToken != "" {
			streamHLSToStorage(
				packageContext,
				writer,
				request,
				hlsDir,
				uploadCallbackURL,
				startedAt,
			)
			return
		}

		output, err := mediaCommandOutput(mediaCommand(
			packageContext,
			ffmpegExecutable,
			packageHLSArgs(request, hlsDir)...,
		))
		if err != nil {
			details := sanitizedFFmpegDetails(
				string(output),
				ffmpegSourceRedactions(request.InputURL, request.InputBasicAuth)...,
			)
			log.Printf("hls-package-error: %v: %s", err, details)
			sendJSON(writer, http.StatusInternalServerError, map[string]string{
				"error": "could not package HLS", "details": details,
			})
			return
		}

		if err := writeHLSBundle(writer, hlsDir); err != nil {
			log.Printf("hls-bundle-error: %v", err)
		}
	}
}

// Placeholder frames overlay the same image as Core's
// priv/static/images/play.png. Embedding it keeps rendering independent of
// external hosts and lets egress policy exclude the public internet.
//
//go:embed assets/play.png
var placeholderOverlayPNG []byte

func placeholderOverlayPath() string {
	return filepath.Join(bundleTempDir(), placeholderOverlayName)
}

// writePlaceholderOverlay places the image in scratch storage, which FFmpeg can
// read, and replaces it atomically so concurrent readers never see a partial file.
func writePlaceholderOverlay(path string) error {
	file, err := os.CreateTemp(filepath.Dir(path), placeholderOverlayName+".*")
	if err != nil {
		return err
	}
	defer func() { _ = os.Remove(file.Name()) }()
	if _, err := file.Write(placeholderOverlayPNG); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	if err := os.Chmod(file.Name(), 0o444); err != nil {
		return err
	}
	return os.Rename(file.Name(), path)
}

func bundleTempDir() string {
	if configured := strings.TrimSpace(os.Getenv("BUNDLE_TEMP_DIR")); configured != "" {
		return configured
	}
	return defaultBundleTempDir
}

func encodeSeekableFrame(
	writer http.ResponseWriter,
	encodeContext context.Context,
	cancel context.CancelFunc,
	request encodeRequest,
	backend string,
) {
	tempFile, err := os.CreateTemp(bundleTempDir(), "mave-frame-*.avif")
	if err != nil {
		sendJSON(writer, http.StatusInternalServerError, map[string]string{"error": "could not create frame workspace"})
		return
	}
	outputPath := tempFile.Name()
	_ = tempFile.Close()
	defer func() { _ = os.Remove(outputPath) }()

	command := mediaCommand(
		encodeContext,
		ffmpegExecutable,
		ffmpegArgsForOutput(request, backend, outputPath)...,
	)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.WaitDelay = 10 * time.Second
	command.Cancel = func() error {
		if command.Process == nil {
			return nil
		}
		return syscall.Kill(-command.Process.Pid, syscall.SIGTERM)
	}
	stderr, err := command.StderrPipe()
	if err != nil {
		sendJSON(writer, http.StatusInternalServerError, map[string]string{"error": "could not open ffmpeg stderr"})
		return
	}

	commandStartedAt := time.Now()
	if err := command.Start(); err != nil {
		log.Printf("ffmpeg-start-error: %v", err)
		sendJSON(writer, http.StatusInternalServerError, map[string]string{"error": "could not start ffmpeg"})
		return
	}

	recent := &recentLog{}
	go readProgress(stderr, request.InputURL, request.InputBasicAuth, recent)
	if err := command.Wait(); err != nil {
		details := recent.string()
		if encodeContext.Err() == nil {
			log.Printf("ffmpeg-seekable-frame-error: %v: %s", err, details)
		}
		sendJSON(writer, http.StatusInternalServerError, map[string]string{
			"error": "ffmpeg could not encode the frame", "details": details,
		})
		return
	}

	output, err := openMediaOutput(outputPath)
	if err != nil {
		sendJSON(writer, http.StatusInternalServerError, map[string]string{"error": "could not read encoded frame"})
		return
	}
	defer output.Close()
	info, err := output.Stat()
	if err != nil || info.Size() <= 0 || info.Size() > maxSeekableFrameBytes {
		sendJSON(writer, http.StatusInternalServerError, map[string]string{"error": "ffmpeg produced an invalid frame"})
		return
	}

	if request.OutputUpload != nil {
		uploadedBytes, parts, uploadErr := streamToMultipartUpload(
			encodeContext,
			writer,
			io.LimitReader(output, maxSeekableFrameBytes+1),
			*request.OutputUpload,
		)
		if uploadErr != nil {
			cancel()
			log.Printf("seekable-frame-multipart-upload-error: %v", uploadErr)
			_ = json.NewEncoder(writer).Encode(uploadEvent{Status: "failed", Error: uploadErr.Error()})
			return
		}
		if err := completeMultipartUpload(encodeContext, request.OutputUpload.CompleteURL, parts); err != nil {
			abortMultipartUploadBestEffort(request.OutputUpload.AbortURL)
			log.Printf("seekable-frame-multipart-complete-error: %v", err)
			_ = json.NewEncoder(writer).Encode(uploadEvent{Status: "failed", Error: err.Error()})
			return
		}
		_ = json.NewEncoder(writer).Encode(uploadEvent{
			Status:          "completed",
			UploadedBytes:   uploadedBytes,
			SizeBytes:       uploadedBytes,
			FFmpegElapsedMS: time.Since(commandStartedAt).Milliseconds(),
			Metrics:         recent.progressSnapshot(),
		})
		return
	}

	writer.Header().Set("Content-Type", "image/avif")
	writer.Header().Set("Content-Disposition", `attachment; filename="frame.avif"`)
	writer.Header().Set("Cache-Control", "no-store")
	declareFFmpegTrailers(writer)
	writer.WriteHeader(http.StatusOK)
	if _, err := io.Copy(writer, io.LimitReader(output, maxSeekableFrameBytes+1)); err != nil {
		cancel()
		return
	}
	setFFmpegTrailers(writer, commandStartedAt, recent)
}

func encodeMultipartAsset(
	encodeContext context.Context,
	writer http.ResponseWriter,
	request encodeRequest,
	backend string,
	upload multipartUpload,
) (int64, int64, map[string]string, error) {
	command := mediaCommand(encodeContext, ffmpegExecutable, ffmpegArgs(request, backend)...)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.WaitDelay = 10 * time.Second
	command.Cancel = func() error {
		if command.Process == nil {
			return nil
		}
		return syscall.Kill(-command.Process.Pid, syscall.SIGTERM)
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		return 0, 0, nil, errors.New("could not open ffmpeg stdout")
	}
	stderr, err := command.StderrPipe()
	if err != nil {
		return 0, 0, nil, errors.New("could not open ffmpeg stderr")
	}
	startedAt := time.Now()
	if err := command.Start(); err != nil {
		return 0, 0, nil, errors.New("could not start ffmpeg")
	}

	recent := &recentLog{}
	go readProgress(stderr, request.InputURL, request.InputBasicAuth, recent)
	encoder, flusher, err := startMultipartResponse(writer)
	if err != nil {
		_ = command.Process.Kill()
		_ = command.Wait()
		return 0, 0, nil, err
	}
	buffer := make([]byte, 64*1024)
	bytesRead, readErr := readMultipartPartWithHeartbeat(
		encodeContext,
		stdout,
		buffer,
		encoder,
		flusher,
		0,
		multipartHeartbeatInterval,
	)
	if bytesRead == 0 {
		commandErr := command.Wait()
		details := recent.string()
		if commandErr != nil {
			details = commandErr.Error() + ": " + details
		}
		return 0, 0, nil, fmt.Errorf("ffmpeg could not start the stream: %s", details)
	}
	reader := io.MultiReader(bytes.NewReader(buffer[:bytesRead]), stdout)
	uploadedBytes, parts, uploadErr := streamToMultipartUploadWithEvents(
		encodeContext,
		reader,
		upload,
		encoder,
		flusher,
		multipartHeartbeatInterval,
	)
	if uploadErr != nil {
		_ = command.Process.Kill()
		_ = command.Wait()
		return 0, 0, nil, uploadErr
	}
	if readErr != nil && !errors.Is(readErr, io.ErrUnexpectedEOF) && !errors.Is(readErr, io.EOF) {
		_ = command.Process.Kill()
		_ = command.Wait()
		abortMultipartUploadBestEffort(upload.AbortURL)
		return 0, 0, nil, readErr
	}
	if err := command.Wait(); err != nil {
		abortMultipartUploadBestEffort(upload.AbortURL)
		return 0, 0, nil, fmt.Errorf("ffmpeg failed before completing the output: %s", recent.string())
	}
	if err := completeMultipartUpload(encodeContext, upload.CompleteURL, parts); err != nil {
		abortMultipartUploadBestEffort(upload.AbortURL)
		return 0, 0, nil, err
	}
	return uploadedBytes, time.Since(startedAt).Milliseconds(), recent.progressSnapshot(), nil
}

func encodeSegments(
	writer http.ResponseWriter,
	encodeContext context.Context,
	request encodeRequest,
	backend string,
) {
	inputPath, cleanup, err := prepareSegmentSource(encodeContext, writer, request)
	defer cleanup()
	if err != nil {
		log.Printf("segment-source-error: %v", err)
		_ = json.NewEncoder(writer).Encode(uploadEvent{Status: "failed", Error: err.Error()})
		return
	}
	request.InputURL = inputPath
	request.InputReferer = ""
	request.InputBasicAuth = ""
	var totalBytes int64
	var totalFFmpegElapsedMS int64
	var metrics map[string]string
	for index, output := range request.OutputUploads {
		frameRequest := request
		frameRequest.Operation = "frame"
		frameRequest.FrameRole = "segment"
		frameRequest.StartSeconds = request.DurationSeconds * float64(index) / float64(request.Count)
		frameRequest.DurationSeconds = 0
		frameRequest.OutputUpload = &output.OutputUpload
		frameRequest.OutputUploads = nil
		frameRequest.Count = 0

		sizeBytes, elapsedMS, frameMetrics, err := encodeMultipartAsset(
			encodeContext,
			writer,
			frameRequest,
			backend,
			output.OutputUpload,
		)
		if err != nil {
			log.Printf("segment-encode-error name=%s: %v", output.Name, err)
			_ = json.NewEncoder(writer).Encode(uploadEvent{
				Status: "failed",
				Error:  fmt.Sprintf("%s: %s", output.Name, err.Error()),
			})
			return
		}
		totalBytes += sizeBytes
		totalFFmpegElapsedMS += elapsedMS
		metrics = frameMetrics
	}

	_ = json.NewEncoder(writer).Encode(uploadEvent{
		Status:          "completed",
		UploadedBytes:   totalBytes,
		SizeBytes:       totalBytes,
		FFmpegElapsedMS: totalFFmpegElapsedMS,
		Metrics:         metrics,
	})
}

func encodeStoryboard(writer http.ResponseWriter, ctx context.Context, request encodeRequest, backend string) {
	// Like segments, storyboards must not parse a partial remote SD rendition.
	inputPath, cleanup, err := prepareSegmentSource(ctx, writer, request)
	defer cleanup()
	if err != nil {
		_ = json.NewEncoder(writer).Encode(uploadEvent{Status: "failed", Error: err.Error()})
		return
	}
	request.InputURL, request.InputReferer, request.InputBasicAuth = inputPath, "", ""
	size, elapsed, metrics, err := encodeMultipartAsset(ctx, writer, request, backend, *request.OutputUpload)
	if err != nil {
		_ = json.NewEncoder(writer).Encode(uploadEvent{Status: "failed", Error: err.Error()})
		return
	}
	_ = json.NewEncoder(writer).Encode(uploadEvent{
		Status: "completed", UploadedBytes: size, SizeBytes: size, FFmpegElapsedMS: elapsed, Metrics: metrics,
	})
}

func encodeHandler(timeout time.Duration, instanceID string, backend string, bearerToken string, slots chan struct{}, tracker *activityTracker) http.HandlerFunc {
	return func(writer http.ResponseWriter, httpRequest *http.Request) {
		writer.Header().Set(instanceHeader, instanceID)
		if httpRequest.Method != http.MethodPost {
			sendJSON(writer, http.StatusMethodNotAllowed, map[string]string{"error": "only POST is allowed"})
			return
		}
		if !authorized(httpRequest, bearerToken) {
			sendJSON(writer, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}

		httpRequest.Body = http.MaxBytesReader(writer, httpRequest.Body, maxRequestBytes)
		decoder := json.NewDecoder(httpRequest.Body)
		decoder.DisallowUnknownFields()
		var request encodeRequest
		if err := decoder.Decode(&request); err != nil {
			sendJSON(writer, http.StatusBadRequest, map[string]string{"error": "invalid JSON: " + err.Error()})
			return
		}
		if err := request.validate(); err != nil {
			sendJSON(writer, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		if slots != nil {
			select {
			case slots <- struct{}{}:
				defer func() { <-slots }()
			default:
				sendJSON(writer, http.StatusTooManyRequests, map[string]string{"error": "busy"})
				return
			}
		}

		finishActivity, accepted := tracker.tryBegin()
		if !accepted {
			sendJSON(writer, http.StatusServiceUnavailable, map[string]string{"error": "draining"})
			return
		}
		defer finishActivity()

		encodeContext, cancel := context.WithTimeout(httpRequest.Context(), timeout)
		defer cancel()
		if request.Operation == "segments" {
			encodeSegments(writer, encodeContext, request, backend)
			return
		}
		if request.Operation == "storyboard" && request.OutputUpload != nil {
			encodeStoryboard(writer, encodeContext, request, backend)
			return
		}
		if requiresSeekableFrameOutput(request) {
			encodeSeekableFrame(writer, encodeContext, cancel, request, backend)
			return
		}
		command := mediaCommand(encodeContext, ffmpegExecutable, ffmpegArgs(request, backend)...)
		command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		command.WaitDelay = 10 * time.Second
		command.Cancel = func() error {
			if command.Process == nil {
				return nil
			}
			return syscall.Kill(-command.Process.Pid, syscall.SIGTERM)
		}
		stdout, err := command.StdoutPipe()
		if err != nil {
			sendJSON(writer, http.StatusInternalServerError, map[string]string{"error": "could not open ffmpeg stdout"})
			return
		}
		stderr, err := command.StderrPipe()
		if err != nil {
			sendJSON(writer, http.StatusInternalServerError, map[string]string{"error": "could not open ffmpeg stderr"})
			return
		}
		commandStartedAt := time.Now()
		if err := command.Start(); err != nil {
			log.Printf("ffmpeg-start-error: %v", err)
			sendJSON(writer, http.StatusInternalServerError, map[string]string{"error": "could not start ffmpeg"})
			return
		}

		recent := &recentLog{}
		progressDone := make(chan struct{})
		go func() {
			readProgress(stderr, request.InputURL, request.InputBasicAuth, recent)
			close(progressDone)
		}()
		if request.Operation == "audio_peaks" {
			// Buffer only bounded metadata, so a failed decode never publishes partial peaks.
			body, readErr := io.ReadAll(io.LimitReader(stdout, 65537))
			if readErr != nil || len(body) > 65536 {
				cancel()
			}
			waitErr := command.Wait()
			<-progressDone
			if readErr != nil || waitErr != nil || len(body) == 0 || len(body) > 65536 {
				sendJSON(writer, http.StatusBadGateway, map[string]string{"error": "audio peaks generation failed"})
				return
			}
			writer.Header().Set("Content-Type", "text/plain; charset=utf-8")
			writer.Header().Set("Cache-Control", "no-store")
			setFFmpegTrailers(writer, commandStartedAt, recent)
			writer.WriteHeader(http.StatusOK)
			_, _ = writer.Write(body)
			return
		}
		var multipartEncoder *json.Encoder
		var multipartFlusher http.Flusher
		if request.OutputUpload != nil {
			multipartEncoder, multipartFlusher, err = startMultipartResponse(writer)
			if err != nil {
				cancel()
				_ = command.Wait()
				return
			}
		}
		buffer := make([]byte, 64*1024)
		var bytesRead int
		var readErr error
		if multipartEncoder != nil {
			bytesRead, readErr = readMultipartPartWithHeartbeat(
				encodeContext,
				stdout,
				buffer,
				multipartEncoder,
				multipartFlusher,
				0,
				multipartHeartbeatInterval,
			)
		} else {
			bytesRead, readErr = stdout.Read(buffer)
		}
		if bytesRead == 0 {
			commandErr := command.Wait()
			<-progressDone
			details := recent.string()
			if commandErr != nil {
				details = commandErr.Error() + ": " + details
			}
			if multipartEncoder != nil {
				detail := strings.TrimSpace("ffmpeg could not start the stream: " + details)
				_ = writeUploadEvent(
					multipartEncoder,
					multipartFlusher,
					uploadEvent{Status: "failed", Error: detail},
				)
			} else {
				sendJSON(writer, http.StatusInternalServerError, map[string]string{
					"error": "ffmpeg could not start the stream", "details": details,
				})
			}
			return
		}
		if request.PackageHLS {
			streamEncodingBundle(
				writer,
				command,
				stdout,
				buffer[:bytesRead],
				readErr,
				buffer,
				encodeContext,
				cancel,
				recent,
				commandStartedAt,
			)
			return
		}
		if request.OutputUpload != nil {
			uploadedBytes, parts, uploadErr := streamToMultipartUploadWithEvents(
				encodeContext,
				io.MultiReader(bytes.NewReader(buffer[:bytesRead]), stdout),
				*request.OutputUpload,
				multipartEncoder,
				multipartFlusher,
				multipartHeartbeatInterval,
			)
			if uploadErr != nil {
				cancel()
				_ = command.Wait()
				log.Printf("multipart-upload-error: %v", uploadErr)
				_ = writeUploadEvent(
					multipartEncoder,
					multipartFlusher,
					uploadEvent{Status: "failed", Error: uploadErr.Error()},
				)
				return
			}
			if err := command.Wait(); err != nil {
				abortMultipartUploadBestEffort(request.OutputUpload.AbortURL)
				log.Printf("ffmpeg-error: %v: %s", err, recent.string())
				_ = writeUploadEvent(
					multipartEncoder,
					multipartFlusher,
					uploadEvent{
						Status: "failed",
						Error:  "ffmpeg failed before completing the output",
					},
				)
				return
			}
			<-progressDone
			metrics := recent.progressSnapshot()
			if err := validateCompletedAudioOutput(request, metrics); err != nil {
				abortMultipartUploadBestEffort(request.OutputUpload.AbortURL)
				details := sanitizedFFmpegDetails(
					recent.string(),
					ffmpegSourceRedactions(request.InputURL, request.InputBasicAuth)...,
				)
				message := err.Error()
				if details != "" {
					message += ": " + details
				}
				log.Printf("ffmpeg-output-validation-error: %s", message)
				_ = writeUploadEvent(
					multipartEncoder,
					multipartFlusher,
					uploadEvent{Status: "failed", Error: message},
				)
				return
			}
			if err := completeMultipartUpload(encodeContext, request.OutputUpload.CompleteURL, parts); err != nil {
				abortMultipartUploadBestEffort(request.OutputUpload.AbortURL)
				log.Printf("multipart-complete-error: %v", err)
				_ = writeUploadEvent(
					multipartEncoder,
					multipartFlusher,
					uploadEvent{Status: "failed", Error: err.Error()},
				)
				return
			}
			_ = writeUploadEvent(
				multipartEncoder,
				multipartFlusher,
				uploadEvent{
					Status:          "completed",
					UploadedBytes:   uploadedBytes,
					SizeBytes:       uploadedBytes,
					FFmpegElapsedMS: time.Since(commandStartedAt).Milliseconds(),
					Metrics:         metrics,
				},
			)
			return
		}

		writer.Header().Set("Content-Type", "video/mp4")
		writer.Header().Set("Content-Disposition", `attachment; filename="encoded.mp4"`)
		writer.Header().Set("Cache-Control", "no-store")
		declareFFmpegTrailers(writer)
		writer.WriteHeader(http.StatusOK)
		if _, err := writer.Write(buffer[:bytesRead]); err != nil {
			cancel()
			_ = command.Wait()
			return
		}
		if flusher, ok := writer.(http.Flusher); ok {
			flusher.Flush()
		}
		if readErr != nil && !errors.Is(readErr, io.EOF) {
			log.Printf("stream-read-error: %v", readErr)
			cancel()
		}
		if _, err := io.CopyBuffer(writer, stdout, buffer); err != nil {
			log.Printf("stream-write-error: %v", err)
			cancel()
		}
		if err := command.Wait(); err != nil {
			if encodeContext.Err() == nil {
				log.Printf("ffmpeg-error: %v: %s", err, recent.string())
			}
			return
		}
		setFFmpegTrailers(writer, commandStartedAt, recent)
	}
}

func concatHandler(timeout time.Duration, instanceID string, bearerToken string, slots chan struct{}, tracker *activityTracker) http.HandlerFunc {
	return func(writer http.ResponseWriter, httpRequest *http.Request) {
		writer.Header().Set(instanceHeader, instanceID)
		if httpRequest.Method != http.MethodPost {
			sendJSON(writer, http.StatusMethodNotAllowed, map[string]string{"error": "only POST is allowed"})
			return
		}
		if !authorized(httpRequest, bearerToken) {
			sendJSON(writer, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}
		httpRequest.Body = http.MaxBytesReader(writer, httpRequest.Body, maxRequestBytes)
		decoder := json.NewDecoder(httpRequest.Body)
		decoder.DisallowUnknownFields()
		var request concatRequest
		if err := decoder.Decode(&request); err != nil {
			sendJSON(writer, http.StatusBadRequest, map[string]string{"error": "invalid JSON: " + err.Error()})
			return
		}
		if err := request.validate(); err != nil {
			sendJSON(writer, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		if slots != nil {
			select {
			case slots <- struct{}{}:
				defer func() { <-slots }()
			default:
				sendJSON(writer, http.StatusTooManyRequests, map[string]string{"error": "busy"})
				return
			}
		}
		finishActivity, accepted := tracker.tryBegin()
		if !accepted {
			sendJSON(writer, http.StatusServiceUnavailable, map[string]string{"error": "draining"})
			return
		}
		defer finishActivity()

		concatContext, cancel := context.WithTimeout(httpRequest.Context(), timeout)
		defer cancel()
		sources, cleanup := prepareConcatSources(concatContext, writer, request)
		defer cleanup()
		if sources.err != nil {
			abortMultipartUploadBestEffort(request.OutputUpload.AbortURL)
			_ = json.NewEncoder(writer).Encode(uploadEvent{Status: "failed", Error: sources.err.Error()})
			return
		}
		localRequest := request
		localRequest.InputReferer = ""
		args := concatFFmpegArgs(localRequest)
		for index, arg := range args {
			if arg == "-i" {
				args[index+1] = sources.manifest
				break
			}
		}
		command := mediaCommand(concatContext, ffmpegExecutable, args...)
		command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		command.WaitDelay = 10 * time.Second
		command.Cancel = func() error {
			if command.Process == nil {
				return nil
			}
			return syscall.Kill(-command.Process.Pid, syscall.SIGTERM)
		}
		stdout, err := command.StdoutPipe()
		if err != nil {
			sendJSON(writer, http.StatusInternalServerError, map[string]string{"error": "could not open ffmpeg stdout"})
			return
		}
		stderr, err := command.StderrPipe()
		if err != nil {
			sendJSON(writer, http.StatusInternalServerError, map[string]string{"error": "could not open ffmpeg stderr"})
			return
		}
		commandStartedAt := time.Now()
		if err := command.Start(); err != nil {
			sendJSON(writer, http.StatusInternalServerError, map[string]string{"error": "could not start ffmpeg"})
			return
		}
		recent := &recentLog{}
		progressDone := make(chan struct{})
		go func() {
			readProgressWithInputs(stderr, request.InputURLs, recent)
			close(progressDone)
		}()
		uploadedBytes, parts, uploadErr := streamToMultipartUpload(
			concatContext,
			writer,
			stdout,
			request.OutputUpload,
		)
		if uploadErr != nil {
			cancel()
			_ = command.Wait()
			log.Printf("concat-multipart-upload-error: %v", uploadErr)
			_ = json.NewEncoder(writer).Encode(uploadEvent{Status: "failed", Error: uploadErr.Error()})
			return
		}
		if err := command.Wait(); err != nil {
			abortMultipartUploadBestEffort(request.OutputUpload.AbortURL)
			log.Printf("concat-ffmpeg-error: %v: %s", err, recent.string())
			_ = json.NewEncoder(writer).Encode(uploadEvent{Status: "failed", Error: "ffmpeg concat failed"})
			return
		}
		<-progressDone
		frames, frameErr := strconv.ParseInt(recent.progressSnapshot()["frame"], 10, 64)
		if frameErr != nil || frames != sources.frames {
			abortMultipartUploadBestEffort(request.OutputUpload.AbortURL)
			_ = json.NewEncoder(writer).Encode(uploadEvent{Status: "failed", Error: "concat output video packet count does not match its inputs"})
			return
		}
		if err := completeMultipartUpload(concatContext, request.OutputUpload.CompleteURL, parts); err != nil {
			abortMultipartUploadBestEffort(request.OutputUpload.AbortURL)
			log.Printf("concat-multipart-complete-error: %v", err)
			_ = json.NewEncoder(writer).Encode(uploadEvent{Status: "failed", Error: err.Error()})
			return
		}
		_ = json.NewEncoder(writer).Encode(uploadEvent{
			Status:          "completed",
			UploadedBytes:   uploadedBytes,
			SizeBytes:       uploadedBytes,
			FFmpegElapsedMS: time.Since(commandStartedAt).Milliseconds(),
			Metrics:         recent.progressSnapshot(),
		})
	}
}

func transferHandler(timeout time.Duration, instanceID string, bearerToken string, slots chan struct{}, tracker *activityTracker) http.HandlerFunc {
	return func(writer http.ResponseWriter, httpRequest *http.Request) {
		writer.Header().Set(instanceHeader, instanceID)
		if httpRequest.Method != http.MethodPost {
			sendJSON(writer, http.StatusMethodNotAllowed, map[string]string{"error": "only POST is allowed"})
			return
		}
		if !authorized(httpRequest, bearerToken) {
			sendJSON(writer, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}

		httpRequest.Body = http.MaxBytesReader(writer, httpRequest.Body, maxRequestBytes)
		decoder := json.NewDecoder(httpRequest.Body)
		decoder.DisallowUnknownFields()
		var request transferRequest
		if err := decoder.Decode(&request); err != nil {
			sendJSON(writer, http.StatusBadRequest, map[string]string{"error": "invalid JSON: " + err.Error()})
			return
		}
		if err := request.validate(); err != nil {
			sendJSON(writer, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		if slots != nil {
			select {
			case slots <- struct{}{}:
				defer func() { <-slots }()
			default:
				sendJSON(writer, http.StatusTooManyRequests, map[string]string{"error": "busy"})
				return
			}
		}

		finishActivity, accepted := tracker.tryBegin()
		if !accepted {
			sendJSON(writer, http.StatusServiceUnavailable, map[string]string{"error": "draining"})
			return
		}
		defer finishActivity()

		transferContext, cancel := context.WithTimeout(httpRequest.Context(), timeout)
		defer cancel()
		sourceRequest, err := http.NewRequestWithContext(transferContext, http.MethodGet, request.InputURL, nil)
		if err != nil {
			sendJSON(writer, http.StatusBadRequest, map[string]string{"error": "could not create source request"})
			return
		}
		if request.InputReferer != "" {
			sourceRequest.Header.Set("Referer", request.InputReferer)
		}
		if request.InputBasicAuth != "" {
			encodedAuth := base64.StdEncoding.EncodeToString([]byte(request.InputBasicAuth))
			sourceRequest.Header.Set("Authorization", "Basic "+encodedAuth)
		}
		sourceResponse, err := performSourceRequest(sourceRequest)
		if err != nil {
			sendJSON(writer, http.StatusBadGateway, map[string]string{"error": "could not open source stream"})
			return
		}
		defer sourceResponse.Body.Close()
		if sourceResponse.StatusCode < 200 || sourceResponse.StatusCode > 299 {
			_, _ = io.Copy(io.Discard, io.LimitReader(sourceResponse.Body, 8*1024))
			sendJSON(writer, http.StatusBadGateway, map[string]string{
				"error": fmt.Sprintf("source returned HTTP %d", sourceResponse.StatusCode),
			})
			return
		}

		startedAt := time.Now()
		hasher := sha256.New()
		uploadedBytes, parts, uploadErr := streamToMultipartUpload(
			transferContext,
			writer,
			io.TeeReader(sourceResponse.Body, hasher),
			request.OutputUpload,
		)
		if uploadErr != nil {
			log.Printf("transfer-multipart-upload-error: %v", uploadErr)
			_ = json.NewEncoder(writer).Encode(uploadEvent{Status: "failed", Error: uploadErr.Error()})
			return
		}
		if err := completeMultipartUpload(transferContext, request.OutputUpload.CompleteURL, parts); err != nil {
			abortMultipartUploadBestEffort(request.OutputUpload.AbortURL)
			log.Printf("transfer-multipart-complete-error: %v", err)
			_ = json.NewEncoder(writer).Encode(uploadEvent{Status: "failed", Error: err.Error()})
			return
		}
		_ = json.NewEncoder(writer).Encode(uploadEvent{
			Status:        "completed",
			UploadedBytes: uploadedBytes,
			SizeBytes:     uploadedBytes,
			SHA256:        hex.EncodeToString(hasher.Sum(nil)),
			Metrics:       map[string]string{"transfer_elapsed_ms": strconv.FormatInt(time.Since(startedAt).Milliseconds(), 10)},
		})
	}
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	timeoutSeconds := 3300
	if configured := os.Getenv("ENCODE_TIMEOUT_SECONDS"); configured != "" {
		if parsed, err := strconv.Atoi(configured); err == nil && parsed > 0 {
			timeoutSeconds = parsed
		}
	}
	backend := os.Getenv("ENCODER_BACKEND")
	if backend == "" {
		backend = "cpu"
	}
	if backend != "cpu" && backend != "nvenc" {
		log.Fatalf("unsupported ENCODER_BACKEND %q", backend)
	}
	maxConcurrent := 0
	if configured := os.Getenv("MAX_CONCURRENT_REQUESTS"); configured != "" {
		if parsed, err := strconv.Atoi(configured); err == nil && parsed > 0 {
			maxConcurrent = parsed
		}
	}
	bearerToken := os.Getenv("BOOSTER_BEARER_TOKEN")
	idleShutdownSeconds := 5 * 60
	if configured := os.Getenv("IDLE_SHUTDOWN_SECONDS"); configured != "" {
		if parsed, err := strconv.Atoi(configured); err == nil && parsed > 0 {
			idleShutdownSeconds = parsed
		}
	}

	if err := writePlaceholderOverlay(placeholderOverlayPath()); err != nil {
		log.Fatalf("could not prepare placeholder overlay: %v", err)
	}

	mux := http.NewServeMux()
	instanceID := newInstanceID()
	readiness := newEncoderReadiness(backend, readinessCacheTTL, runCommand)
	activity := newActivityTracker()
	slots := requestSlots(maxConcurrent)
	mux.HandleFunc("/health", healthHandler(instanceID, readiness, activity))
	// Scaleway excludes the configured health-check path from autoscaling.
	// Upload warmup traffic therefore needs a distinct route so held requests
	// count toward the concurrent-request scaling threshold.
	mux.HandleFunc("/warmup", healthHandler(instanceID, readiness, activity))
	mux.HandleFunc("/idle", idleHandler(activity, bearerToken, time.Duration(idleShutdownSeconds)*time.Second))
	mux.HandleFunc("/drain", drainHandler(activity, bearerToken, time.Duration(idleShutdownSeconds)*time.Second))
	mux.HandleFunc("/resume", resumeHandler(activity, bearerToken))
	mux.HandleFunc("/encode", encodeHandler(time.Duration(timeoutSeconds)*time.Second, instanceID, backend, bearerToken, slots, activity))
	mux.HandleFunc("/concat", concatHandler(time.Duration(timeoutSeconds)*time.Second, instanceID, bearerToken, slots, activity))
	mux.HandleFunc("/transfer", transferHandler(time.Duration(timeoutSeconds)*time.Second, instanceID, bearerToken, slots, activity))
	mux.HandleFunc("/package-hls", packageHLSHandler(time.Duration(timeoutSeconds)*time.Second, instanceID, bearerToken, slots, activity))

	server := &http.Server{
		Addr: "0.0.0.0:" + port, Handler: mux,
		ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second,
	}
	log.Printf("streaming encoder instance=%s backend=%s max_concurrent=%d listening on %s", instanceID, backend, maxConcurrent, server.Addr)
	if err := server.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
