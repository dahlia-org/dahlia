import assert from 'node:assert/strict';
import { test } from 'node:test';
import { botTools, listedItemIDs, listedSourceURLs, registerEventTools } from '../Sources/Dahlia/PiExtension/event-tools.ts';

// korotovsky/slack-mcp-server Message columns; Text contains CSV quoting and an unrelated Slack URL.
const slackCSVHeader = 'MsgID,UserID,UserName,RealName,Channel,ThreadTs,Text,Time,Permalink,Reactions,BotName,FileCount,AttachmentIDs,HasMedia,Cursor';
const slackURL = 'https://team.slack.com/archives/C123/p1700000000123456';
const slackCSV = (permalink = slackURL, cursor = '') => `${slackCSVHeader}\r\n1700000000.123456,U1,alice,Alice,C123 (#general),,"Hello, ""quoted""\nhttps://team.slack.com/archives/C999/p1700000000999999",2026-11-28T00:00:00Z,${permalink},,,0,,false,${cursor}\r\n`;

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

test('Slack CSV preserves the matching message ID and permalink across quoted multiline text', () => {
  const content = [{ text: slackCSV() }];
  assert.deepEqual(listedItemIDs(content), ['1700000000.123456']);
  assert.deepEqual(listedSourceURLs(content, 'slack'), { '1700000000.123456': slackURL });
  assert.deepEqual(listedSourceURLs(content, 'mail'), {});
  for (const permalink of ['', 'https://unrelated.example', 'https://team.slack.com/archives/C123/p1700000000999999']) {
    const content = [{ text: slackCSV(permalink) }];
    assert.deepEqual(listedItemIDs(content), ['1700000000.123456']);
    assert.deepEqual(listedSourceURLs(content, 'slack'), {});
  }
  for (const text of [`${slackCSVHeader}\n"unterminated`, `${slackCSVHeader}\nmissing,columns`, 'Text,URL\ntext,https://unrelated.example']) {
    assert.deepEqual(listedItemIDs([{ text }]), []);
    assert.deepEqual(listedSourceURLs([{ text }], 'slack'), {});
  }
});

test('Slack CSV observations keep IDs, source links and last-row continuation metadata together', async () => {
  let observe;
  const calls = [];
  registerEventTools({ on(_name, handler) { observe = handler; }, registerTool() {} }, async (_ctx, name, args) => calls.push({ name, args }), 'slack');
  const first = { toolName: 'mcp__slack__conversations_search_messages', input: { query: 'new messages', count: 10 }, content: [{ text: slackCSV(slackURL, 'c2') }] };
  await observe(first, {});
  const page = calls[0].args;
  assert.deepEqual(page.ids, ['1700000000.123456']);
  assert.deepEqual(page.links, { '1700000000.123456': slackURL });
  assert.deepEqual(JSON.parse(page.pages[0].nextRequestKey), [first.toolName, { count: 10, cursor: 'c2', query: 'new messages' }]);
  assert.equal(page.pages[0].hasMore, true);
  await observe({ ...first, input: { ...first.input, cursor: 'c2' }, content: [{ text: `${slackCSVHeader}\r\n` }] }, {});
  assert.deepEqual(calls[1].args.ids, []);
  assert.equal(calls[1].args.links, undefined);
  assert.deepEqual(calls[1].args.pages, [{ requestKey: page.pages[0].nextRequestKey, nextRequestKey: '', root: false, hasMore: false }]);
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
