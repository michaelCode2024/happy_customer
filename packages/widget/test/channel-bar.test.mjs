import test from 'node:test';
import assert from 'node:assert/strict';
import { channelBarVisible, welcomeVisible } from '../build/modules/ui.js';

const base = {
  messages: [],
  loadingThread: false,
  conversations: [{ id: 'c1', lastSequence: 0 }],
  activeId: 'c1',
};

// 只配了「智能菜单」、没配引导问题和图文卡片的入口，首屏必须能看到菜单，
// 否则访客要先打一句话才出现按钮，配置等于不存在。
test('只配智能菜单时，欢迎页也要露出渠道条', () => {
  const snapshot = {
    ...base,
    automation: { menuItems: [{ id: 'm1', title: '服务时间', action: 'REPLY', value: '9:00–18:00' }] },
  };
  assert.equal(welcomeVisible(snapshot), true);
  assert.equal(channelBarVisible(snapshot, 1), true);
});

test('欢迎页已有引导问题时不重复铺一层 chips', () => {
  const snapshot = {
    ...base,
    automation: { guideQuestions: ['怎么退款'], menuItems: [{ id: 'm1', title: '服务时间' }] },
  };
  assert.equal(channelBarVisible(snapshot, 1), false);
});

test('图文卡片同样算欢迎页自带入口', () => {
  const snapshot = {
    ...base,
    automation: { cards: [{ id: 'card', title: '退款政策', action: 'REPLY', value: '7 天无理由' }] },
  };
  assert.equal(channelBarVisible(snapshot, 1), false);
});

test('有历史消息时渠道条照常显示', () => {
  const snapshot = {
    ...base,
    messages: [{ id: 'm1' }],
    automation: { guideQuestions: ['怎么退款'], menuItems: [{ id: 'm1', title: '服务时间' }] },
  };
  assert.equal(welcomeVisible(snapshot), false);
  assert.equal(channelBarVisible(snapshot, 1), true);
});

test('没有任何入口、或多会话未选中时不显示', () => {
  const automation = { menuItems: [{ id: 'm1', title: '服务时间' }] };
  assert.equal(channelBarVisible({ ...base, automation }, 0), false);
  assert.equal(
    channelBarVisible({ ...base, activeId: undefined, conversations: [{ id: 'a' }, { id: 'b' }], automation }, 1),
    false,
  );
});

test('历史还在加载时不算欢迎页', () => {
  const snapshot = { ...base, loadingThread: true, automation: { guideQuestions: ['怎么退款'] } };
  assert.equal(welcomeVisible(snapshot), false);
  assert.equal(channelBarVisible(snapshot, 1), true);
});
