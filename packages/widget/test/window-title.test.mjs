import test from 'node:test';
import assert from 'node:assert/strict';
import { windowTitle } from '../build/modules/config.js';

test('宿主指定的窗口名优先于入口聊天窗口名称', () => {
  assert.equal(windowTitle('掌柜咨询', '用户端咨询', true), '掌柜咨询');
  assert.equal(windowTitle('用户端咨询', '', true), '用户端咨询');
  assert.equal(windowTitle('通语客服', '用户端咨询', true), '用户端咨询');
  assert.equal(windowTitle('通语客服', '', true), '在线客服');
  assert.equal(windowTitle('', '', false), '通语客服');
});
