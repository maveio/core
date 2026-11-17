import { test } from 'node:test'
import assert from 'node:assert/strict'
import { EditorState, TextSelection } from 'prosemirror-state'
import { history, undo, redo } from 'prosemirror-history'
import { descriptionSchema, documentFromMoments, momentsFromDocument, formatMoment, parseMoment, replaceWithMoment, DescriptionDocumentHook, activeMomentRange, invalidMomentIds, invalidTypedTimeRanges, backspaceMoment, momentDeletionPlugin, momentDeletionKey } from '../js/hooks/description_document.js'

const moments = [
  { id: 'first', start: 2.5, text: 'A plane.\nA new paragraph.' },
  { id: 'second', start: 6, text: 'A woman.' },
]

test('document round trips paragraphs, identities and time labels', () => {
  assert.deepEqual(momentsFromDocument(documentFromMoments(moments)).moments, moments)
})

test('adding and removing a time label preserves all surrounding text', () => {
  let state = EditorState.create({ doc: documentFromMoments([moments[0]]) })
  state = state.apply(state.tr.insert(5, descriptionSchema.nodes.moment.create({ id: 'new', start: 3 })))
  assert.equal(momentsFromDocument(state.doc).moments.length, 2)
  state = state.apply(state.tr.delete(5, 6))
  assert.deepEqual(momentsFromDocument(state.doc).moments, [moments[0]])
})

test('removing the first time label preserves an unanchored draft', () => {
  const doc = documentFromMoments([moments[0]])
  let state = EditorState.create({ doc })
  state = state.apply(state.tr.delete(1, 2))
  assert.deepEqual(momentsFromDocument(state.doc).moments, [{ id: 'unplaced', start: null, text: moments[0].text }])
})

test('normal typing, undo and redo keep time labels intact', () => {
  let state = EditorState.create({ doc: documentFromMoments(moments), plugins: [history()] })
  const dispatch = tr => { state = state.apply(tr) }
  dispatch(state.tr.setSelection(TextSelection.create(state.doc, 2)).insertText('Look: '))
  assert.match(momentsFromDocument(state.doc).moments[0].text, /^Look: /)
  assert.equal(undo(state, dispatch), true)
  assert.deepEqual(momentsFromDocument(state.doc).moments, moments)
  assert.equal(redo(state, dispatch), true)
  assert.match(momentsFromDocument(state.doc).moments[0].text, /^Look: /)
})

test('time labels support minutes, hours and millisecond precision', () => {
  assert.equal(formatMoment(36.55), '00:36.550')
  assert.equal(parseMoment('00:36.550'), 36.55)
  assert.equal(parseMoment('01:02:03.125'), 3723.125)
  assert.equal(parseMoment('00:65'), null)
})

test('converting a typed label keeps the space and caret on the same line', () => {
  let state = EditorState.create({ doc: descriptionSchema.nodes.doc.create(null,
    descriptionSchema.nodes.paragraph.create(null, descriptionSchema.text('[00:40]'))) })
  state = state.apply(replaceWithMoment(state, 1, 8, 40, 'new'))
  assert.equal(state.doc.childCount, 1)
  assert.equal(state.selection.from, 3)
  assert.equal(state.doc.firstChild.lastChild.text, ' ')
  state = state.apply(state.tr.insertText('A plane.'))
  assert.equal(state.doc.childCount, 1)
  assert.deepEqual(momentsFromDocument(state.doc).moments, [{ id: 'new', start: 40, text: 'A plane.' }])
})

test('a time label at the end of a block creates a separate moment before the following block', () => {
  const original = [
    { id: 'first', start: 10, text: 'First description.' },
    { id: 'next', start: 50, text: 'Following description.' },
  ]
  let state = EditorState.create({ doc: documentFromMoments(original), plugins: [history()] })
  const at = state.doc.firstChild.nodeSize - 1
  state = state.apply(state.tr.insertText('[00:40]', at))
  const beforeConversion = state
  state = state.apply(replaceWithMoment(state, at, at + 7, 40, 'new'))
  assert.equal(state.doc.childCount, 3)
  assert.equal(state.selection.$from.parent, state.doc.child(1))
  assert.equal(state.selection.$from.parentOffset, 2)
  state = state.apply(state.tr.insertText('New description.'))
  const result = momentsFromDocument(state.doc)
  assert.deepEqual(result.moments, [original[0], { id: 'new', start: 40, text: 'New description.' }, original[1]])
  assert.equal(result.ends.get('first'), state.doc.firstChild.nodeSize)
  assert.ok(result.ends.get('first') < result.ends.get('new'))
  assert.ok(result.ends.get('new') < result.ends.get('next'))
  assert.equal(beforeConversion.doc.childCount, 2)
})

test('an empty new moment has no block feedback between its label and the caret', () => {
  const doc = documentFromMoments([{ id: 'new', start: 40, text: '' }])
  const state = EditorState.create({ doc })
  const decorations = DescriptionDocumentHook.decorations.call({ feedback: [{ after_id: 'new', state: 'within' }] }, state)
  assert.equal(decorations.find().length, 0)
})

test('shared feedback stays after a trailing empty moment when its group contains text', () => {
  const doc = documentFromMoments([{ id: 'first', start: 2, text: 'A plane.' }, { id: 'new', start: 3, text: '' }])
  const state = EditorState.create({ doc })
  const decorations = DescriptionDocumentHook.decorations.call({ feedback: [{ after_id: 'new', state: 'within', count: 1 }] }, state)
  assert.equal(decorations.find().length, 1)
  assert.equal(decorations.find()[0].from, doc.content.size)
})

test('pause feedback sits after the paragraph, outside its text and caret', () => {
  const doc = documentFromMoments([{ id: 'first', start: 2, text: 'A plane.' }])
  const { ends } = momentsFromDocument(doc)
  assert.equal(ends.get('first'), doc.firstChild.nodeSize)
  assert.ok(ends.get('first') > doc.firstChild.content.size)
})

test('a following time label does not move the previous pause feedback to its paragraph', () => {
  const doc = documentFromMoments(moments)
  const { ends } = momentsFromDocument(doc)
  const firstEnd = doc.child(0).nodeSize + doc.child(1).nodeSize
  assert.equal(ends.get('first'), firstEnd)
  assert.equal(ends.get('second'), doc.content.size)
  assert.notEqual(ends.get('first'), ends.get('second'))
})

test('active moment ends with its speech and stays inactive between descriptions', () => {
  const doc = documentFromMoments(moments)
  const windows = [{ id: 'first', start: 2.5, end: 3.5 }, { id: 'second', start: 6, end: 7 }]
  assert.equal(activeMomentRange(doc, 1, windows), null)
  assert.equal(activeMomentRange(doc, 2.5, windows).id, 'first')
  assert.equal(activeMomentRange(doc, 3.5, windows), null)
  assert.equal(activeMomentRange(doc, 5.9, windows), null)
  assert.equal(activeMomentRange(doc, 6, windows).id, 'second')
  assert.equal(activeMomentRange(doc, 7, windows), null)
  assert.equal(activeMomentRange(doc, 3, windows).id, 'first')
  assert.equal(activeMomentRange(doc, 3, windows).to, activeMomentRange(doc, 6, windows).from)
  assert.equal(activeMomentRange(doc, 3, []), null)
})

test('out-of-order, duplicate and out-of-video labels are marked invalid', () => {
  const doc = documentFromMoments([
    { id: 'a', start: 30, text: 'First' },
    { id: 'b', start: 20, text: 'Earlier' },
    { id: 'c', start: 20, text: 'Duplicate' },
    { id: 'd', start: 100, text: 'Outside' },
  ])
  assert.deepEqual([...invalidMomentIds(doc, 90)], ['a', 'b', 'c', 'd'])
  assert.deepEqual([...invalidMomentIds(documentFromMoments(moments), 90)], [])
})

test('typed invalid times are marked before they become labels', () => {
  const doc = documentFromMoments([{ id: 'first', start: 10, text: 'Text [00:05] [00:99] [00:12]' }])
  const ranges = invalidTypedTimeRanges(doc, 90)
  assert.equal(ranges.length, 2)
  assert.deepEqual(ranges.map(range => doc.textBetween(range.from, range.to)), ['[00:05]', '[00:99]'])
})

test('backspace arms a new label without a real selection, then removes only the label', () => {
  let state = EditorState.create({ doc: documentFromMoments([]), plugins: [momentDeletionPlugin()] })
  state = state.apply(replaceWithMoment(state, 1, 1, 40, 'new'))
  const original = state.doc
  const dispatch = tr => { state = state.apply(tr) }
  assert.equal(backspaceMoment(state, dispatch), true)
  assert.ok(state.selection instanceof TextSelection)
  assert.equal(state.selection.from, 3)
  assert.equal(momentDeletionKey.getState(state).id, 'new')
  assert.equal(state.doc, original)
  assert.equal(backspaceMoment(state, dispatch), true)
  assert.equal(state.doc.firstChild.textContent, ' ')
  assert.equal(state.doc.childCount, 1)
})

test('backspace directly after a label preserves its following description', () => {
  let state = EditorState.create({ doc: documentFromMoments([{ id: 'first', start: 2, text: 'Keep this text.' }]), plugins: [momentDeletionPlugin()] })
  state = state.apply(state.tr.setSelection(TextSelection.create(state.doc, 2)))
  const dispatch = tr => { state = state.apply(tr) }
  assert.equal(backspaceMoment(state, dispatch), true)
  assert.equal(backspaceMoment(state, dispatch), true)
  assert.equal(state.doc.textContent, 'Keep this text.')
})


test('typing after arming a label cancels deletion and leaves the label intact', () => {
  let state = EditorState.create({ doc: documentFromMoments([]), plugins: [momentDeletionPlugin()] })
  state = state.apply(replaceWithMoment(state, 1, 1, 40, 'new'))
  backspaceMoment(state, tr => { state = state.apply(tr) })
  state = state.apply(state.tr.insertText('Text'))
  assert.equal(momentDeletionKey.getState(state), null)
  assert.equal(momentsFromDocument(state.doc).moments[0].id, 'new')
})
