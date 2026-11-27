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

test('Slack CSV history and replies complete cursor chains when limit is omitted or cleared', async () => {
  for (const name of ['conversations_history', 'conversations_replies']) {
    for (const limit of ['50', '1d']) {
      let observe;
      const pages = [];
      registerEventTools({ on(_name, handler) { observe = handler; }, registerTool() {} }, async (_ctx, _name, args) => pages.push(...args.pages), 'slack');
      const toolName = `mcp__custom_slack__${name}`;
      const scope = { channel_id: 'C123', include_activity_messages: false, ...(name === 'conversations_replies' ? { thread_ts: '1700000000.123456' } : {}) };
      const root = { ...scope, limit };
      await observe({ toolName, input: root, content: [{ text: slackCSV(slackURL, 'c2') }] }, {});
      await observe({ toolName, input: { ...scope, cursor: 'c2' }, content: [{ text: slackCSV(slackURL, 'c3') }] }, {});
      await observe({ toolName, input: { ...scope, cursor: 'c3', limit: '' }, content: [{ text: `${slackCSVHeader}\r\n` }] }, {});
      assert.equal(pages[0].root, true);
      assert.deepEqual(JSON.parse(pages[0].requestKey)[1], root);
      assert.equal(pages[0].nextRequestKey, pages[1].requestKey);
      assert.equal(pages[1].nextRequestKey, pages[2].requestKey);
      assert.equal(pages[2].nextRequestKey, '');
      assert.equal(pages[2].hasMore, false);
      assert.deepEqual(pages.slice(1).map(page => page.root), [false, false]);
      // The normalized continuation still retains every content-shaping argument.
      for (const change of [{ channel_id: 'C999' }, { include_activity_messages: true }, { limit: '100' },
        ...(scope.thread_ts ? [{ thread_ts: '1700000000.999999' }] : [])]) {
        await observe({ toolName, input: { ...scope, cursor: 'c2', ...change }, content: [{ text: `${slackCSVHeader}\r\n` }] }, {});
        assert.notEqual(pages[0].nextRequestKey, pages.at(-1).requestKey);
      }
    }
  }
});

test('Slack cursor limit clearing does not weaken search, JSON or other tool request identities', async () => {
  for (const [toolName, text] of [
    ['mcp__slack__conversations_search_messages', slackCSV(slackURL, 'c2')],
    ['mcp__other__history', slackCSV(slackURL, 'c2')],
    ['mcp__slack__conversations_history', JSON.stringify({ messages: [], nextCursor: 'c2', has_more: true })],
  ]) {
    let observe;
    const pages = [];
    registerEventTools({ on(_name, handler) { observe = handler; }, registerTool() {} }, async (_ctx, _name, args) => pages.push(...args.pages), 'slack');
    const root = { query: 'new messages', count: 10, limit: '50', filter: { channel: 'C123' } };
    await observe({ toolName, input: root, content: [{ text }] }, {});
    assert.deepEqual(JSON.parse(pages[0].nextRequestKey), [toolName, { ...root, cursor: 'c2' }]);
    for (const change of [{ limit: '' }, { count: 100 }, { query: 'other' }, { filter: { channel: 'C999' } }]) {
      await observe({ toolName, input: { ...root, cursor: 'c2', ...change }, content: [{ text }] }, {});
      assert.notEqual(pages[0].nextRequestKey, pages.at(-1).requestKey);
    }
  }
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
