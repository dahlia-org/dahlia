import assert from 'node:assert/strict';
import { test } from 'node:test';
import { botTools, listedItemIDs, listedSourceURLs, registerEventTools } from '../Sources/Dahlia/PiExtension/event-tools.ts';

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

test('source links use structured item metadata and ignore message body links', () => {
  const content = value => [{ text: JSON.stringify(value) }];
  const mail = content({ items: [
    { id: '19abcdef', threadId: '19abc', body: 'https://unrelated.example', url: 'https://unrelated.example' },
    { id: '../bad', threadId: '19abc' },
    { id: '19abc' },
  ] });
  assert.deepEqual(listedSourceURLs(mail, 'mail'), { '19abcdef': 'https://mail.google.com/mail/u/0/#all/19abcdef' });
  assert.deepEqual(listedSourceURLs(mail, ''), {});
  const message = { ts: '1700000000.123456', text: 'https://unrelated.example', permalink: 'https://team.slack.com/archives/C123/p1700000000123456' };
  assert.deepEqual(listedSourceURLs(content({ messages: { matches: [message] } }), 'slack'), { [message.ts]: message.permalink });
  for (const permalink of [undefined, 'https://unrelated.example', 'https://team.slack.com.evil.example/archives/C123/p1700000000123456',
    'https://team.slack.com/archives/C123/p1700000000999999', 'http://team.slack.com/archives/C123/p1700000000123456']) {
    assert.deepEqual(listedSourceURLs(content({ messages: [{ ...message, permalink }] }), 'slack'), {});
  }
});

test('tool observations attach item links to intakeSeen and omit them on failures', async () => {
  let observe;
  const calls = [];
  registerEventTools({ on(_name, handler) { observe = handler; }, registerTool() {} }, async (_ctx, name, args) => calls.push({ name, args }), 'mail');
  const event = { toolName: 'mcp__mail__search_messages', input: {}, content: [{ text: JSON.stringify({ items: [{ id: '19abc', threadId: '19abc' }] }) }] };
  await observe(event, {});
  assert.deepEqual(calls[0].args.links, { '19abc': 'https://mail.google.com/mail/u/0/#all/19abc' });
  await observe({ ...event, isError: true }, {});
  assert.deepEqual(calls[1], { name: 'intakeReadFailed', args: {} });
});

test('calendar and reminder schemas expose only bot-owned operations', async () => {
  const calendar = botTools.bot.find(tool => tool.name === 'calendar_read');
  const reminder = botTools.bot.find(tool => tool.name === 'remind');
  assert.deepEqual(calendar.parameters.required, []);
  assert.deepEqual(reminder.parameters.required, ['at', 'note']);
});
