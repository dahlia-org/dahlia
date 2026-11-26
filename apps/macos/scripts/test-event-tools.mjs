import assert from 'node:assert/strict';
import { test } from 'node:test';
import { botTools, listedItemIDs, registerEventTools } from '../Sources/Dahlia/PiExtension/event-tools.ts';

test('selection tool requires a stable key and a reason, and bridges the new shape', async () => {
  const registered = [];
  const calls = [];
  registerEventTools({ on() {}, registerTool(tool) { registered.push(tool); } }, async (_ctx, name, args) => {
    calls.push({ name, args });
    return { success: true, recorded: 1, limit_reached: false };
  });
  const tool = registered[0];
  assert.deepEqual(tool.parameters.properties.items.items.required, ['key', 'note']);
  assert.deepEqual(Object.keys(tool.parameters.properties.items.items.properties).sort(), ['key', 'topic', 'note', 'ref', 'occurred_at', 'sender'].sort());
  const args = { items: [{ key: 'mail-1', topic: 'thread-1', note: 'A response is needed', ref: { messageId: 'mail-1' } }] };
  const result = await tool.execute('', args, undefined, undefined, {});
  assert.deepEqual(calls, [{ name: 'eventRecord', args }]);
  assert.equal(JSON.parse(result.content[0].text).recorded, 1);
});

test('read accounting recognizes Gmail messages and Slack messages', () => {
  assert.deepEqual(listedItemIDs([{ text: JSON.stringify({ items: [{ id: 'm1', threadId: 't1' }] }) }]), ['m1']);
  assert.deepEqual(listedItemIDs([{ text: JSON.stringify({ messages: { matches: [{ ts: '1.2' }] } }) }]), ['1.2']);
  assert.equal(botTools.bot.some(tool => tool.name === 'inbox_read'), true);
});

test('calendar and reminder schemas expose only bot-owned operations', async () => {
  const calendar = botTools.bot.find(tool => tool.name === 'calendar_read');
  const reminder = botTools.bot.find(tool => tool.name === 'remind');
  assert.deepEqual(calendar.parameters.required, []);
  assert.deepEqual(reminder.parameters.required, ['at', 'note']);
});
