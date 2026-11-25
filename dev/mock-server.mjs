#!/usr/bin/env node
// Fake ax-kit Mac for the iOS app: every screen gets data without the real server.
// Speaks ax-kit's docs/APP-PROTOCOL.md v1 plus the additions in PROTOCOL-REQUESTS.md (marked R1…R10).
// No dependencies. Run: node dev/mock-server.mjs [--port 47790]
// Pair: the app's "개발용 가짜 맥에 연결" button, or the printed axkit:// link (code 123456).
import http from 'node:http';
import { randomBytes } from 'node:crypto';
import { deflateSync, crc32 } from 'node:zlib';

const PORT = Number(process.argv[process.argv.indexOf('--port') + 1]) || 47790;
const HOST = process.env.MOCK_HOST ?? '127.0.0.1';
const NONCE = 'dev';
const CODE = '123456';
const KST = 9 * 3600_000;

// ---------- time helpers (KST) ----------
const now = () => new Date();
const iso = (d) => d.toISOString();
const kstYmd = (d) => new Date(d.getTime() + KST).toISOString().slice(0, 10);
const kstAt = (ymd, hh, mm = 0) => new Date(Date.parse(`${ymd}T${String(hh).padStart(2, '0')}:${String(mm).padStart(2, '0')}:00+09:00`));
const plusDays = (ymd, n) => kstYmd(new Date(Date.parse(`${ymd}T12:00:00+09:00`) + n * 86400_000));
const ago = (min) => new Date(Date.now() - min * 60_000);

// ---------- bots (R1) + teams (R16) + meeting rooms (R17) ----------
const TIER_DEFAULT = { lead: 'A', staff: 'B', reviewer: 'S' };
// A team = 1 lead + staff (3) + a reviewer for dev teams. The lead's id is the team id, and the team room is its channel.
function makeTeam({ id, name, purpose, kind = 'general', tiers = TIER_DEFAULT, staffCount = 3, reviewerCount, status = 'idle', statusText, isNew, decidedBy = 'owner', reason }) {
  const reviewers = reviewerCount ?? (kind === 'dev' ? 1 : 0);
  const t = { ...TIER_DEFAULT, ...tiers };
  const bots = [{ id, name: `${name} 팀장`, role: purpose, channel: id, rank: 'lead', team: id, tier: t.lead, status, statusText, isNew,
    instructions: `${name}팀을 이끌어요. 대표님 지시와 비서가 맡긴 일을 받아 직원에게 나누고, 끝난 일은 검수를 거쳐 쉬운 말로 보고해요. 돈이 들거나 밖으로 보내는 일은 꼭 결재를 받아요.`, instructionsBy: decidedBy === 'ai' ? 'ai' : 'default' }];
  for (let i = 1; i <= staffCount; i++) bots.push({ id: `${id}-${i}`, name: `${name} 직원 ${i}`, role: `${name} 일을 나눠 해요`, channel: id, rank: 'staff', team: id, tier: t.staff, status: 'idle',
    instructions: `팀장이 맡긴 일을 해요. 모르는 건 추측하지 말고 팀장에게 물어요. 끝나면 무엇을 했는지 한두 문장으로 알려요.`, instructionsBy: 'default' });
  for (let i = 1; i <= reviewers; i++) bots.push({ id: reviewers === 1 ? `${id}-review` : `${id}-review-${i}`, name: reviewers === 1 ? `${name} 검수` : `${name} 검수 ${i}`, role: '끝난 일을 꼼꼼히 확인해요', channel: id, rank: 'reviewer', team: id, tier: t.reviewer, status: 'idle' });
  return { team: { id, name: `${name}팀`, purpose, channel: id, kind, members: bots.map((b) => b.id), decidedBy, ...(reason ? { reason } : {}) }, bots };
}
function makeGroup(id, label, summary, teamSpecs) {
  const built = teamSpecs.map(makeTeam);
  return { id, label, summary, meetingChannel: `meeting:${id}`, teams: built.map((x) => x.team), bots: built.flatMap((x) => x.bots) };
}
const groups = [
  makeGroup('hanbit', '한빛랩', '앱 만드는 회사', [
    { id: 'dev', name: '개발', purpose: '앱·서버 코드를 고쳐요', kind: 'dev', status: 'working', statusText: '로그인 화면 고치는 중' },
    { id: 'design', name: '디자인', purpose: '화면 시안을 만들어요', status: 'off', statusText: '오늘은 쉬는 중' },
  ]),
  makeGroup('moa', '모아카페', '동네 카페 2호점', [
    { id: 'store', name: '매장', purpose: '매출·직원 근무표를 챙겨요' },
    { id: 'stock', name: '재고', purpose: '원두·우유 주문을 챙겨요', status: 'waiting', statusText: '주문 승인 기다리는 중' },
    { id: 'marketing', name: '홍보', purpose: '인스타 글을 써요', isNew: true, staffCount: 2, reviewerCount: 0, tiers: { lead: 'B', staff: 'C' }, decidedBy: 'ai', reason: '글 쓰는 일이 적어서 직원 2명, 싼 등급으로 충분해요.' },
  ]),
  makeGroup('me', '나', '개인 생활', [{ id: 'money', name: '가계부', purpose: '지출을 정리해요', staffCount: 3 }]),
];
const allBots = () => groups.flatMap((g) => g.bots);
const botById = (id) => allBots().find((b) => b.id === id);
// The team lead speaks for a team room.
const botByChannel = (ch) => allBots().find((b) => b.channel === ch && b.rank === 'lead');
const groupByMeeting = (ch) => groups.find((g) => g.meetingChannel === ch);
const knownChannel = (ch) => !!botByChannel(ch) || !!groupByMeeting(ch);
const who = (b) => ({ id: b.id, name: b.name });
/** Bot-to-bot line in plain words (the A2A payload itself never leaves the Mac). */
const talk = (ch, fromId, toId, text, at) => append({ type: 'message', role: 'assistant', channel: ch, author: who(botById(fromId)), ...(toId ? { to: who(botById(toId)) } : {}), text }, at);

// ---------- event log ----------
const events = [];
// Grows across restarts (seconds since 2026), like the real server's persisted log.
let seq = Math.floor((Date.now() - Date.UTC(2026, 0, 1)) / 1000);
const listeners = new Set();
function append(draft, at = now()) {
  const event = { ...draft, seq: ++seq, at: iso(at) };
  events.push(event);
  if (events.length > 500) events.shift();
  for (const l of listeners) l(event);
  return event;
}
// §4 `activity`: outside the log (no seq, no id, never replayed); a new stream gets each busy room once.
const activityListeners = new Set();
const busyRooms = new Map(); // channel ('' = main) -> activity
function activity(channel, state, step) {
  const a = { type: 'activity', ...(channel ? { channel } : {}), state, ...(step ? { step } : {}), at: iso(now()) };
  if (state === 'idle') busyRooms.delete(channel); else busyRooms.set(channel, a);
  for (const l of activityListeners) l(a);
}
const say = (text, extra = {}, at = now()) => append({ type: 'message', role: 'assistant', text, ...extra }, at);
const botSay = (ch, text, extra = {}) => {
  const bot = botByChannel(ch);
  return say(text, { channel: ch, author: { id: bot.id, name: bot.name }, ...extra });
};
const cards = new Map(); // cardId -> card event (open ones)
// R15: one question per topic. Answered topics are never asked again; an open one is updated in place.
const answeredTopics = new Map(); // topic -> { state, option, at }
function openCard(card) {
  if (card.topic && answeredTopics.has(card.topic)) return null;
  const sameOpen = card.topic && [...cards.values()].find((c) => c.topic === card.topic);
  if (sameOpen) card = { ...card, cardId: sameOpen.cardId };
  const event = append({ type: 'card', effectLabels: card.effects.map(effectLabel), expiresAt: iso(new Date(Date.now() + 6 * 3600_000)), ...card });
  cards.set(card.cardId, event);
  return event;
}
function effectLabel(e) { return { read: '읽기', write: '저장', send: '보내기', pay: '결제', delete: '지우기' }[e] ?? e; }

// Seed history: a morning in the life.
(function seed() {
  const t = (m) => ago(m);
  append({ type: 'notice', text: '좋은 아침이에요. 오늘은 일정 3개, 결재할 것 4건이 있어요. 맑음, 최고 14도.' }, t(300));
  append({ type: 'message', role: 'owner', text: '앱 로그인 화면이 가끔 하얗게 나온대. 봐 줄래?' }, t(240));
  say('네, 개발 팀장에게 맡길게요. 끝나면 알려 드릴게요.', {}, t(239));
  append({ type: 'delegation', bot: { id: 'dev', name: '개발 팀장' }, botChannel: 'dev', task: '로그인 화면이 하얗게 나오는 문제 고치기', state: 'started' }, t(239));
  talk('dev', 'dev', null, '비서가 맡긴 일이에요: 로그인 화면이 가끔 하얗게 나와요. 같이 봐요.', t(238));
  talk('dev', 'dev', 'dev-1', '직원 1님, 느린 인터넷에서 다시 해 볼래요?', t(236));
  talk('dev', 'dev-1', 'dev', '해 봤어요. 글꼴 파일을 다 받을 때까지 화면이 멈춰 있어요.', t(200));
  talk('dev', 'dev', 'dev-2', '직원 2님, 기본 글꼴로 먼저 그리게 고쳐 줄래요?', t(198));
  talk('dev', 'dev-2', 'dev', '고쳤어요. 이제 바로 그려지고, 글꼴은 나중에 바뀌어요.', t(130));
  talk('dev', 'dev', 'dev-review', '검수님, 확인 부탁해요.', t(125));
  append({ type: 'message', role: 'assistant', channel: 'dev', author: { id: 'dev-review', name: '개발 검수' }, to: { id: 'dev', name: '개발 팀장' }, text: '로그인 화면 10번 열어 봤어요. 하얀 화면 없이 다 잘 떴어요.' }, t(90));
  append({ type: 'delegation', bot: { id: 'dev', name: '개발 팀장' }, botChannel: 'dev', task: '로그인 화면이 하얗게 나오는 문제 고치기', state: 'done', summary: '느린 인터넷에서 글꼴을 기다리던 문제였어요. 고쳤고 검사도 통과했어요.' }, t(89));
  talk('meeting:hanbit', 'dev', null, '앱 2.0 출시 날짜를 정하려고 모였어요. 로그인 문제는 오늘 고쳤어요.', t(80));
  talk('meeting:hanbit', 'design', 'dev', '새 화면 시안은 목요일까지 드릴 수 있어요.', t(79));
  talk('meeting:hanbit', 'dev', 'design', '좋아요. 시안 받고 3일이면 붙일 수 있어요.', t(78));
  talk('meeting:hanbit', 'dev', null, '정리: 다음 주 화요일 출시를 대표님께 제안할게요.', t(77));
  say('한빛랩 팀장회의 결론: 앱 2.0을 다음 주 화요일에 내는 걸 제안해요. 팀장회의 방에서 볼 수 있어요.', {}, t(76));
  append({ type: 'message', role: 'assistant', channel: 'stock', author: { id: 'stock', name: '재고 팀장' }, text: '원두가 이번 주 금요일쯤 떨어질 것 같아요. 주문할지 결재에 올려 뒀어요.' }, t(60));
  append({ type: 'message', role: 'assistant', channel: 'store', author: { id: 'store', name: '매장 팀장' }, text: '어제 매출은 84만 2천원이에요. 지난주 같은 요일보다 12% 많아요.' }, t(50));
  append({ type: 'message', role: 'assistant', channel: 'money', author: { id: 'money', name: '가계부 팀장' }, text: '이번 달 식비가 예산의 80%를 넘었어요. 남은 날은 11일이에요.' }, t(45));
  const card = (c, labels, hours, at) => cards.set(c.cardId, append({ type: 'card', ...c, effectLabels: labels, expiresAt: iso(new Date(Date.now() + hours * 3600_000)) }, at));
  card({ cardId: 'beans', summary: '어떻게 주문할까요?', effects: ['pay'], amount: { value: 145000, currency: 'KRW' }, note: '모아카페 원두가 이번 주 금요일쯤 떨어질 것 같아요. 재고 봇이 오늘 아침 재고를 세어 보고 알려 왔어요(남은 양 3kg, 매주 4.8kg 사용).', remember: { label: '앞으로 15만원 이하 원두 주문은 알아서 할게요', detail: '늘 사던 곳·같은 원두일 때만. 주문하면 알려 드려요.' }, channel: 'stock', author: { id: 'stock', name: '재고 팀장' },
    options: [
      { id: 'beans:usual', label: '커피상회 5kg (14만 5천원)', detail: '14만 5천원 · 금요일 도착 · 지난달과 같은 원두', tone: 'primary' },
      { id: 'beans:compare', label: '더 싼 곳 찾아 줘', detail: '비교표를 만들어서 다시 물어볼게요' },
      { id: 'beans:3kg', label: '3kg만 (8만 9천원)', detail: '8만 9천원 · 다음 주에 다시 확인' },
      { id: 'beans:no', label: '이번엔 주문 안 해', tone: 'danger' }] }, ['결제'], 20, t(59));
  card({ cardId: 'deploy-login', summary: '언제 내보낼까요?', effects: ['write'], note: '개발 팀장이 오늘 오전에 한빛 앱의 로그인 화면이 하얗게 멈추던 문제를 고쳤고, 검사 봇이 10번 확인했어요. 내보내면 사용자 앱이 30분 안에 바뀌어요.', remember: { label: '앞으로 검사를 통과한 수정은 같은 방식으로 알아서 내보낼게요' }, channel: 'dev', author: { id: 'dev', name: '개발 팀장' },
    options: [
      { id: 'deploy:now', label: '지금 바로', detail: '사용자 약 120명이 쓰는 중이에요', tone: 'primary' },
      { id: 'deploy:night', label: '오늘 밤 12시', detail: '쓰는 사람이 가장 적을 때예요' },
      { id: 'deploy:friday', label: '금요일 정기 배포에 같이', detail: '다른 수정 2개와 함께 나가요' },
      { id: 'deploy:hold', label: '보류', tone: 'danger' }] }, ['저장'], 10, t(30));
  card({ cardId: 'meet-park', summary: '언제로 할까요?', effects: ['send'], note: '투자사 박대표님이 어제 저녁 메일로 시리즈 A 후속 미팅을 다음 주에 하자고 했어요. 고른 시간으로 답장을 보내고 캘린더에 넣을게요.',
    options: [
      { id: 'meet:tue', label: '화요일 오후 2시', detail: '박대표님이 제안한 시간 · 그 시간 비어 있어요', tone: 'primary' },
      { id: 'meet:wed', label: '수요일 오전 10시로 제안', detail: '오전이 집중하기 좋다고 하셨어요' },
      { id: 'meet:online', label: '온라인 30분만', detail: '줌 링크를 만들어 보내요' },
      { id: 'meet:no', label: '이번엔 정중히 거절', tone: 'danger' }] }, ['보내기'], 8, t(25));
  card({ cardId: 'insta-post', topic: 'insta:post:latte', summary: '이 글을 인스타에 올릴까요?', effects: ['send'], channel: 'marketing', author: { id: 'marketing', name: '홍보 팀장' },
    note: '홍보팀이 오늘 아침 "아이스 라떼 1+1" 행사 글과 사진을 만들었어요. 모아카페 인스타 계정에 올려요.',
    attachments: [{ id: 'poster', name: 'latte-poster.png', contentType: 'image/png', url: 'files/poster' }],
    options: [{ id: 'insta:now', label: '지금 올리기', tone: 'primary' }, { id: 'insta:evening', label: '오후 6시에 올리기' }, { id: 'insta:redo', label: '사진 다시 만들기' }, { id: 'insta:no', label: '올리지 않기', tone: 'danger' }] }, ['보내기'], 6, t(15));
  card({ cardId: 'mail-quote', summary: '어떻게 보낼까요?', effects: ['send'], note: '거래처 김대리님이 오늘 오전에 11월 납품 견적을 오늘 안에 보내 달라고 했어요. 견적서(1,240만원)는 문서에 준비돼 있어요.',
    options: [
      { id: 'mail:now', label: '지금 메일로 보내기', detail: '견적서_11월.pdf 첨부', tone: 'primary' },
      { id: 'mail:9am', label: '내일 아침 9시에 예약', detail: '출근 시간에 맞춰 보내요' },
      { id: 'mail:discount', label: '10% 깎아서 보내기', detail: '새 견적서를 먼저 보여 드릴게요' },
      { id: 'mail:no', label: '보내지 않기', tone: 'danger' }] }, ['보내기'], 4, t(20));
  say('요청한 파일이에요: 견적서_11월.pdf', { attachments: [{ id: 'doc_quote.pdf', name: '견적서_11월.pdf', contentType: 'application/pdf', size: 48213, url: 'files/doc_quote.pdf' }] }, t(8));
  say('오늘 오후 3시 투자사 미팅 자료는 문서 탭 "한빛랩 › 투자" 에 정리해 뒀어요.', { choices: [{ id: 'brief:open', label: '요약해 줘' }, { id: 'brief:later', label: '나중에' }] }, t(10));
})();

// ---------- simulated assistant ----------
function later(ms, fn) { setTimeout(fn, ms); }
function respond(text, channel) {
  const t = text.toLowerCase();
  if (channel) {
    const meeting = groupByMeeting(channel);
    if (meeting) {
      const leads = meeting.bots.filter((b) => b.rank === 'lead');
      leads.slice(0, 3).forEach((b, i) => later(900 + i * 1200, () => talk(channel, b.id, null, i === 0 ? `대표님 말씀 "${text.slice(0, 30)}" 받았어요. 각 팀 의견 모을게요.` : `${b.name.replace(' 팀장', '')}팀은 이번 주 안에 할 수 있어요.`)));
      return;
    }
    const lead = botByChannel(channel);
    if (!lead) return;
    const staff = allBots().find((b) => b.team === lead.team && b.rank === 'staff');
    const reviewer = allBots().find((b) => b.team === lead.team && b.rank === 'reviewer');
    later(900, () => talk(channel, lead.id, null, `알겠어요. "${text.slice(0, 40)}" 바로 할게요.`));
    if (staff) later(1800, () => talk(channel, lead.id, staff.id, `${staff.name.split(' ').slice(-2).join(' ')}님, 이거 맡아 줄래요?`));
    if (staff) later(3500, () => talk(channel, staff.id, lead.id, '끝냈어요. 확인해 주세요.'));
    if (reviewer) later(4800, () => talk(channel, reviewer.id, lead.id, '확인했어요. 문제없어요.'));
    later(5600, () => talk(channel, lead.id, null, '끝났어요. 캘린더 "한 일"에도 남겨 뒀어요.'));
    return;
  }
  if (/개발|버그|앱|코드|화면|bug|app|fix/.test(t)) {
    later(700, () => say('개발 팀장에게 맡길게요.'));
    later(900, () => append({ type: 'delegation', bot: { id: 'dev', name: '개발 팀장' }, botChannel: 'dev', task: text.slice(0, 60), state: 'started' }));
    later(1500, () => botSay('dev', `비서가 맡긴 일: ${text.slice(0, 60)}. 시작할게요.`));
    later(6000, () => botSay('dev', '다 고쳤어요. 검수 확인도 받았어요.'));
    later(6200, () => append({ type: 'delegation', bot: { id: 'dev', name: '개발 팀장' }, botChannel: 'dev', task: text.slice(0, 60), state: 'done', summary: '고쳤고 검사도 통과했어요.' }));
    return;
  }
  if (/인스타|홍보|광고|insta|post/.test(t)) {
    later(700, () => append({ type: 'delegation', bot: { id: 'marketing', name: '홍보 팀장' }, botChannel: 'marketing', task: text.slice(0, 60), state: 'started' }));
    later(2500, () => botSay('marketing', '글 초안을 만들었어요: "오늘만 아이스 라떼 1+1" 올릴까요?'));
    return;
  }
  if (/사 |사줘|주문|결제|구매|buy|order/.test(t)) {
    later(800, () => say('살지 물어보는 결재를 올렸어요.'));
    later(1000, () => openCard({ cardId: `buy-${Date.now()}`, summary: '어디서 살까요?', effects: ['pay'], amount: { value: 23800, currency: 'KRW' }, note: `방금 "${text.slice(0, 30)}"을(를) 사 달라고 하셔서 세 곳을 찾아봤어요.`,
      options: [{ id: 'buy:cheap', label: '가장 싼 곳(쿠팡)', detail: '2만 3,800원 · 내일 도착', tone: 'primary' }, { id: 'buy:fast', label: '가장 빠른 곳(컬리)', detail: '2만 6,900원 · 오늘 밤 도착' },
        { id: 'buy:more', label: '더 찾아봐 줘', detail: '후기 좋은 곳까지 비교해요' }, { id: 'buy:no', label: '사지 않기', tone: 'danger' }] }));
    return;
  }
  if (/매일|마다|반복|아침마다|매주|every/.test(t)) {
    const id = `job-${Date.now()}`;
    jobs.groups[0].jobs.unshift({ id, name: text.slice(0, 30), detail: '대화에서 만든 반복 작업', schedule: { kind: 'daily', at: '08:00', timezone: 'Asia/Seoul' }, scheduleLabel: '매일 08:00', enabled: true, running: false, lastRun: null, nextRunAt: iso(kstAt(plusDays(kstYmd(now()), 1), 8)), source: 'ax' });
    later(800, () => say('반복 작업을 만들었어요. 더보기 › 반복 작업에서 끄고 켤 수 있어요.'));
    return;
  }
  later(800, () => say(`네, "${text.slice(0, 40)}" 알겠어요. 필요한 게 생기면 물어볼게요.`, { choices: [{ id: `more:${Date.now()}`, label: '고마워' }] }));
}

// ---------- views ----------
const today = () => kstYmd(now());

const docLayers = [
  { id: 'company', label: '회사', summary: '회사마다 하는 일' },
  { id: 'project', label: '프로젝트', summary: '지금 진행 중인 일' },
  { id: 'people', label: '사람', summary: '자주 연락하는 사람' },
  { id: 'life', label: '생활', summary: '나와 집' },
];
const docNodes = [
  ['hanbit', '한빛랩', 'company', 'hanbit', 3], ['moa', '모아카페', 'company', 'moa', 3], ['me', '나에 대해', 'life', 'me', 3],
  ['hb-app', '한빛 앱 2.0', 'project', 'hanbit', 2], ['hb-invest', '투자 유치(시리즈 A)', 'project', 'hanbit', 2], ['hb-hiring', '개발자 채용', 'project', 'hanbit', 1],
  ['hb-login', '로그인 화면 문제 기록', 'project', 'hanbit', 1], ['hb-qa', '출시 전 검사 목록', 'project', 'hanbit', 1],
  ['moa-menu', '겨울 메뉴', 'project', 'moa', 1], ['moa-stock', '원두·우유 거래처', 'project', 'moa', 1], ['moa-staff', '직원 근무표', 'project', 'moa', 1], ['moa-insta', '인스타 운영', 'project', 'moa', 1],
  ['p-kim', '김대리(거래처)', 'people', 'hanbit', 1], ['p-park', '박대표(투자사)', 'people', 'hanbit', 1], ['p-lee', '이점장', 'people', 'moa', 1], ['p-coffee', '커피상회', 'people', 'moa', 1],
  ['life-health', '건강 기록', 'life', 'me', 1], ['life-money', '가계부 규칙', 'life', 'me', 1], ['life-family', '가족 일정', 'life', 'me', 1],
].map(([id, title, layer, group, weight]) => ({ id, title, layer, group, weight, summary: `${title}에 대한 정리`, updatedAt: iso(ago(Math.floor(Math.random() * 5000))) }));
const docLinks = [
  ['hanbit', 'hb-app'], ['hanbit', 'hb-invest'], ['hanbit', 'hb-hiring'], ['hb-app', 'hb-login'], ['hb-app', 'hb-qa'], ['hb-login', 'hb-qa'],
  ['hb-invest', 'p-park'], ['hb-app', 'p-kim'], ['moa', 'moa-menu'], ['moa', 'moa-stock'], ['moa', 'moa-staff'], ['moa', 'moa-insta'],
  ['moa-stock', 'p-coffee'], ['moa-staff', 'p-lee'], ['me', 'life-health'], ['me', 'life-money'], ['me', 'life-family'], ['life-money', 'moa'], ['me', 'hanbit'], ['me', 'moa'],
].map(([from, to]) => ({ from, to }));

function documentDetail(id) {
  const node = docNodes.find((n) => n.id === id);
  if (!node) return null;
  if (node.markdown) return { id, title: node.title, layer: node.layer, markdown: node.markdown, updatedAt: node.updatedAt, related: node.related };
  const related = docLinks.filter((l) => l.from === id || l.to === id).map((l) => (l.from === id ? l.to : l.from)).map((rid) => docNodes.find((n) => n.id === rid)).filter(Boolean).map((n) => ({ id: n.id, title: n.title }));
  const body = {
    'hb-invest': '## 한눈에\n- 목표: **30억** 시리즈 A\n- 다음 만남: 오늘 오후 3시, 박대표\n\n## 준비할 것\n1. 지난 분기 매출표\n2. 앱 2.0 출시 날짜\n3. 채용 계획\n\n## 메모\n박대표는 *월간 사용자 수*를 가장 먼저 물어봐요.',
    'hb-login': '## 무슨 일이 있었나\n느린 인터넷에서 로그인 화면이 하얗게 멈췄어요.\n\n## 원인\n글꼴 파일을 다 받을 때까지 화면을 그리지 않았어요.\n\n## 고친 것\n글꼴을 기다리지 않고 기본 글꼴로 먼저 그려요. 검사 봇 확인 완료',
  }[id] ?? `## ${node.title}\n${node.summary}.\n\n- 처음 정리: 문서 스캔(온보딩)\n- 최근 바뀜: 비서가 대화에서 배운 내용\n\n관련 문서는 아래에서 바로 열 수 있어요.`;
  return { id, title: node.title, layer: node.layer, markdown: body, updatedAt: node.updatedAt, related };
}

const addedEvents = [];
// §36: CALENDARS=one (older Mac / single calendar: no calendar fields) · limited (only the main one is readable).
const calendarMode = process.env.CALENDARS ?? 'many';
const calendarList = calendarMode === 'many' ? [
  { id: 'me@example.com', name: '내 캘린더', primary: true, writable: true, account: 'me@example.com' },
  { id: 'cafe-123@group.calendar.google.com', name: '모아카페', primary: false, writable: true, description: '매장 일정', account: 'me@example.com' },
  { id: 'hanbit-456@group.calendar.google.com', name: '한빛랩', primary: false, writable: true, description: '회사 일정', account: 'me@example.com' },
  { id: 'ko.south_korea#holiday@group.v.calendar.google.com', name: '대한민국의 휴일', primary: false, writable: false, account: 'me@example.com' },
] : calendarMode === 'limited' ? [{ id: 'me@example.com', name: '내 캘린더', primary: true, writable: true }] : null;
function calendarOf(title) {
  if (calendarMode !== 'many') return undefined;
  if (/카페|원두/.test(title)) return '모아카페';
  if (/투자|앱 2.0/.test(title)) return '한빛랩';
  if (/결제일/.test(title)) return '대한민국의 휴일';
  return '내 캘린더';
}

function calendarMonth(month) {
  const [y, m] = month.split('-').map(Number);
  const daysIn = new Date(Date.UTC(y, m, 0)).getUTCDate();
  const t = today();
  const days = [];
  const plans = [
    ['투자사 미팅(박대표)', 15, 0, 60, '강남 사무실'], ['카페 직원 회의', 10, 0, 30, '모아카페'], ['치과', 18, 30, 40, null], ['앱 2.0 출시 회의', 11, 0, 60, '온라인'],
    ['원두 도착', 9, 0, 0, null], ['가족 저녁', 19, 0, 120, '본가'],
  ];
  const dones = [
    ['로그인 화면 문제 고침', 'dev', '개발 팀장'], ['어제 매출 정리', 'store', '매장 팀장'], ['카드 지출 7건 분류', 'money', '가계부 팀장'], ['인스타 글 1개 올림', 'marketing', '홍보 팀장'],
    ['출시 전 검사 32개 통과', 'dev-review', '개발 검수'], ['아침 브리핑 보냄', 'main', '비서'], ['메일 12통 정리', 'main', '비서'],
  ];
  for (let d = 1; d <= daysIn; d++) {
    const date = `${month}-${String(d).padStart(2, '0')}`;
    const events = [];
    const done = [];
    const h = (d * 7 + m * 3) % 11;
    if (h % 3 === 0 && date !== t) {
      const [title, hh, mm, dur, place] = plans[(d + m) % plans.length];
      const start = kstAt(date, hh, mm);
      events.push({ id: `ev-${date}-1`, title, start: iso(start), end: dur ? iso(new Date(start.getTime() + dur * 60_000)) : undefined, allDay: false, place });
    }
    if (date === t) {
      events.push({ id: `ev-${date}-1`, title: '카페 직원 회의', start: iso(kstAt(date, 10)), end: iso(kstAt(date, 10, 30)), allDay: false, place: '모아카페' });
      events.push({ id: `ev-${date}-2`, title: '투자사 미팅(박대표)', start: iso(kstAt(date, 15)), end: iso(kstAt(date, 16)), allDay: false, place: '강남 사무실' });
      events.push({ id: `ev-${date}-3`, title: '카페 마감 정산', start: iso(kstAt(date, 21)), allDay: false });
    }
    if (d % 9 === 0) events.push({ id: `ev-${date}-ad`, title: '카드 결제일', start: iso(kstAt(date, 0)), allDay: true });
    if (date <= t) {
      const n = date === t ? 3 : (h % 4);
      for (let i = 0; i < n; i++) {
        const [title, botId, botName] = dones[(d + i * 2) % dones.length];
        done.push({ id: `done-${date}-${i}`, title, at: iso(kstAt(date, 9 + i * 3, 10)), bot: botId === 'main' ? { id: 'main', name: '비서' } : { id: botId, name: botName }, detail: `${botName}${/[가-힣]/.test(botName.slice(-1)) && (botName.slice(-1).charCodeAt(0) - 0xac00) % 28 ? '이' : '가'} 한 일이에요.` });
      }
    }
    for (const e of events) if (!e.calendar) e.calendar = calendarOf(e.title);
    days.push({ date, events, done });
  }
  for (const ev of addedEvents) {
    const d = days.find((x) => x.date === kstYmd(new Date(ev.start)));
    if (d) { d.events.push(ev); d.events.sort((x, y) => x.start.localeCompare(y.start)); }
  }
  const out = { month, timezone: 'Asia/Seoul', days };
  if (calendarList) out.calendars = calendarList;
  if (calendarMode === 'limited') out.calendarsLimited = true;
  return out;
}

const jobs = {
  generatedAt: iso(now()),
  groups: [
    { id: 'ax', label: '비서가 하는 일', jobs: [
      { id: 'brief', name: '아침 브리핑', detail: '일정·날씨·중요 메일을 아침에 알려 줘요', schedule: { kind: 'daily', at: '07:30', timezone: 'Asia/Seoul' }, scheduleLabel: '매일 07:30', enabled: true, running: false, lastRun: { startedAt: iso(ago(300)), ok: true }, nextRunAt: iso(kstAt(plusDays(today(), 1), 7, 30)), source: 'ax' },
      { id: 'mail', name: '메일 정리', detail: '광고는 치우고 답할 메일만 모아요', schedule: { kind: 'interval', everySec: 1800 }, scheduleLabel: '30분마다', enabled: true, running: true, lastRun: { startedAt: iso(ago(12)), ok: true }, nextRunAt: iso(new Date(Date.now() + 18 * 60_000)), source: 'ax' },
      { id: 'spend', name: '카드 지출 분류', detail: '카드 문자를 가계부에 적어요', schedule: { kind: 'interval', everySec: 3600 }, scheduleLabel: '1시간마다', enabled: true, running: false, lastRun: { startedAt: iso(ago(40)), ok: true }, nextRunAt: iso(new Date(Date.now() + 20 * 60_000)), source: 'ax' },
      { id: 'sales', name: '카페 매출 보고', detail: '어제 매출을 매장 봇이 정리해요', schedule: { kind: 'daily', at: '09:00', timezone: 'Asia/Seoul' }, scheduleLabel: '매일 09:00', enabled: true, running: false, lastRun: { startedAt: iso(ago(200)), ok: false, error: '포스기 연결이 끊겨 있었어요' }, nextRunAt: iso(kstAt(plusDays(today(), 1), 9)), source: 'ax' },
      { id: 'weekly', name: '주간 회고', detail: '한 주 동안 한 일을 정리해요', schedule: { kind: 'daily', at: '20:00', timezone: 'Asia/Seoul' }, scheduleLabel: '매주 일요일 20:00', enabled: false, running: false, lastRun: null, nextRunAt: null, source: 'ax' },
    ] },
    { id: 'other', label: '이 맥에서 도는 것 (보기만)', jobs: [
      { id: 'backup', name: '밤 백업', scheduleLabel: '매일 03:30', enabled: true, running: false, lastRun: { startedAt: iso(ago(600)), ok: true }, nextRunAt: null, source: 'launchd', toggleable: false },
    ] },
  ],
};

const categories = [['food', '식비'], ['cafe', '카페'], ['groceries', '장보기'], ['transport', '교통'], ['shopping', '쇼핑'], ['living', '생활'], ['health', '의료'], ['culture', '문화'], ['subscription', '구독'], ['ai', 'AI 서비스'], ['other', '기타']].map(([id, label]) => ({ id, label }));
const catLabel = (id) => categories.find((c) => c.id === id)?.label ?? '기타';
let spendBudget = 1_200_000;
const spendEntries = [
  ['김밥천국', 8500, 'food', 0], ['스타벅스', 6100, 'cafe', 0], ['카카오T', 12400, 'transport', 1], ['이마트', 84200, 'groceries', 1], ['쿠팡', 32900, 'shopping', 2],
  ['Claude', 29000, 'ai', 3], ['넷플릭스', 17000, 'subscription', 4], ['약국', 7800, 'health', 4], ['CGV', 28000, 'culture', 5], ['배달의민족', 24500, 'food', 5],
  ['GS25', 4300, 'food', 6], ['교보문고', 18000, 'culture', 7], ['다이소', 11000, 'living', 8], ['한국전력', 52000, 'living', 9], ['티머니', 1450, 'transport', 9],
  ['ChatGPT', 29000, 'ai', 10], ['올리브영', 23900, 'shopping', 11], ['맥도날드', 9800, 'food', 12], ['블루보틀', 7500, 'cafe', 13], ['홈플러스', 61000, 'groceries', 14],
].map(([merchant, amount, category, daysAgo], i) => {
  const at = new Date(Date.now() - daysAgo * 86400_000 - i * 3600_000);
  return { id: `sp${i}`, at: iso(at), date: kstYmd(at), merchant, amount, category, categoryLabel: catLabel(category), categorySource: 'rule', source: i % 4 === 0 ? 'app' : 'sms', hasReceipt: false };
});
function spending(month) {
  const list = spendEntries.filter((e) => e.date.startsWith(month)).sort((a, b) => b.at.localeCompare(a.at));
  const by = new Map();
  for (const e of list) { const c = by.get(e.category) ?? { category: e.category, label: catLabel(e.category), amount: 0, count: 0 }; c.amount += e.amount; c.count += 1; by.set(e.category, c); }
  const total = list.reduce((s, e) => s + e.amount, 0);
  return {
    month, currency: 'KRW', total, count: list.length, byCategory: [...by.values()].sort((a, b) => b.amount - a.amount),
    recent: list.slice(0, 20).map(({ at, merchant, amount, category }) => ({ at, merchant, amount, category })), previousMonth: month, previousTotal: 1_032_000, budget: spendBudget,
    days: [], entries: list, categories, claims: null,
    subscriptions: [{ key: 'netflix', merchant: '넷플릭스', cadence: 'monthly', amount: 17000, currency: 'KRW', nextDate: plusDays(today(), 12), lapsed: false }, { key: 'claude', merchant: 'Claude', cadence: 'monthly', amount: 29000, currency: 'KRW', nextDate: plusDays(today(), 0), lapsed: false }],
  };
}

function usage(period) {
  const k = { day: 1, week: 6, month: 19 }[period] ?? 1;
  const daily = [];
  const n = period === 'day' ? 24 : period === 'week' ? 7 : 19;
  for (let i = n - 1; i >= 0; i--) {
    const d = period === 'day' ? `${today()}T${String(23 - i).padStart(2, '0')}:00` : plusDays(today(), -i);
    const calls = Math.round(20 + 15 * Math.sin(i) + (i % 3) * 6);
    daily.push({ date: d, calls, failures: i % 5 === 0 ? 1 : 0, costUsd: Math.round(calls * 0.004 * 1000) / 1000 });
  }
  return {
    period, since: iso(ago(k * 1440)), until: iso(now()),
    totals: { calls: 412 * k, failures: 6 * k, failureRate: 0.014, costUsd: 1.83 * k, inputTokens: 912000 * k, outputTokens: 141000 * k },
    byModel: [
      { providerId: 'anthropic', model: 'claude-sonnet-5-5', calls: 230 * k, failures: 2 * k, failureRate: 0.009, costUsd: 1.2 * k, inputTokens: 0, outputTokens: 0 },
      { providerId: 'deepseek', model: 'deepseek-v4', calls: 150 * k, failures: 3 * k, failureRate: 0.02, costUsd: 0.21 * k, inputTokens: 0, outputTokens: 0 },
      { providerId: 'openai', model: 'gpt-5.4-mini', calls: 32 * k, failures: 1 * k, failureRate: 0.03, costUsd: 0.42 * k, inputTokens: 0, outputTokens: 0 },
    ],
    byPurpose: [{ purpose: 'chat', calls: 180 * k, failures: 1, failureRate: 0, costUsd: 0.9 * k }, { purpose: 'mail.triage', calls: 120 * k, failures: 2, failureRate: 0, costUsd: 0.3 * k }, { purpose: 'dev', calls: 80 * k, failures: 3, failureRate: 0, costUsd: 0.5 * k }],
    byBot: [{ botId: 'main', name: '비서', calls: 190 * k, costUsd: 0.8 * k }, { botId: 'dev', name: '개발 팀장', calls: 120 * k, costUsd: 0.7 * k }, { botId: 'money', name: '가계부 팀장', calls: 60 * k, costUsd: 0.1 * k }, { botId: 'marketing', name: '홍보 팀장', calls: 42 * k, costUsd: 0.23 * k }],
    daily, budget: { dailyUsd: 5, monthlyUsd: 80 },
  };
}

// §23 프로젝트 가져오기: found folders, the owner's saved picks (path -> {name, company}), and a pretend scan.
const foundProjects = [
  { path: '/Users/me/dev/hanbit/web', display: '~/dev/hanbit/web', name: 'hanbit-web', company: '한빛랩', remote: 'github.com/hanbit/web', daysAgo: 0, claude: 34, codex: 5 },
  { path: '/Users/me/dev/hanbit/api', display: '~/dev/hanbit/api', name: 'hanbit-api', company: '한빛랩', remote: 'github.com/hanbit/api', daysAgo: 1, claude: 12, codex: 0 },
  { path: '/Users/me/dev/hanbit/landing', display: '~/dev/hanbit/landing', name: 'landing', company: '한빛랩', daysAgo: 40, claude: 1, codex: 0 },
  { path: '/Users/me/dev/latte/pos', display: '~/dev/latte/pos', name: 'latte-pos', company: '라떼', remote: 'github.com/latte-cafe/pos', daysAgo: 3, claude: 8, codex: 2 },
  { path: '/Users/me/dev/side/notes-app', display: '~/dev/side/notes-app', name: 'notes-app', company: 'side', daysAgo: 12, claude: 0, codex: 4 },
];
let savedProjects = new Map([['/Users/me/dev/hanbit/web', { name: 'hanbit-web', company: '한빛랩' }], ['/Users/me/dev/old/thing', { name: 'old-thing', company: '한빛랩' }]]);
let projectScan = { status: 'done', phase: 'done', counts: { files: 812, repos: 2, docs: 40, sessions: 46, drive: 0, summarized: 2, signals: 0 }, finishedAt: iso(new Date(Date.now() - 86400_000)) };
// §24 team plan: proposed teams from the work map, before they are built.
function freshTeamPlan() {
  return { id: `p${Date.now()}`, createdAt: iso(now()), status: 'proposed', teams: [
    { company: '스튜디오 오름', name: '브랜드A 리뉴얼', purpose: '로고·가이드 개편', kind: 'general',
      roles: [{ title: '레퍼런스 조사', does: '비슷한 사례를 모아요' }, { title: '시안 정리', does: '시안을 버전별로 정리해요' }],
      tasks: ['주간 시안 진행 점검', '클라이언트 피드백 정리'],
      routines: [{ title: '시안 진행 점검', instruction: '이번 주 시안 진행 상황을 정리해 알려 줘', schedule: { kind: 'weekly', day: 'mon', at: '09:30' } }] },
    { company: '스튜디오 오름', name: '홈페이지 개발', purpose: '회사 홈페이지 새로 만들기', kind: 'dev',
      roles: [{ title: '프론트엔드', does: '화면을 만들어요' }, { title: '백엔드', does: '문의 폼과 서버를 맡아요' }],
      tasks: ['배포 전 점검'], routines: [] },
    { company: '나', name: '가계부', purpose: '카드 내역 정리와 예산 확인', kind: 'general',
      roles: [{ title: '내역 정리', does: '카드 문자를 모아 분류해요' }],
      tasks: ['매일 지출 정리'], routines: [{ title: '지출 정리', instruction: '어제 쓴 돈을 분류해서 알려 줘', schedule: { kind: 'daily', at: '08:00' } }, { title: '예산 확인', instruction: '이번 달 예산 남은 것을 알려 줘', schedule: { kind: 'every', hours: 12 } }] },
  ] };
}
let teamPlan = freshTeamPlan();
function teamPlanCard() {
  const lines = teamPlan.teams.map((t) => `■ ${t.company} · ${t.name} — ${t.roles.map((r) => r.title).join(', ')}`).join('\n');
  openCard({ cardId: `teamplan-${teamPlan.id}`, topic: `bots:team-plan:${teamPlan.id}`, summary: '일 지도대로 이렇게 팀을 만들까요?', effects: ['write'],
    note: `${lines}\n앱의 "팀 구조"에서 이름·역할·루틴을 고친 뒤 만들 수도 있어요.`,
    options: [{ id: 'build', label: '이대로 만들기', tone: 'primary' }, { id: 'fix-in-app', label: '앱에서 고칠게요' }, { id: 'no', label: '만들지 않기', tone: 'danger' }] });
}
function applyTeamPlan() {
  if (teamPlan.status === 'applied') return { teams: 0, routines: 0 };
  const made = { teams: teamPlan.teams.length, routines: teamPlan.teams.reduce((n, t) => n + t.routines.length, 0) };
  teamPlan = { ...teamPlan, status: 'applied', appliedAt: iso(now()) };
  append({ type: 'notice', text: `팀 ${made.teams}개와 루틴 ${made.routines}개를 만들었어요.` });
  return made;
}
function validPlanTeams(list) {
  const text = (x, max) => typeof x === 'string' && x.trim().length >= 1 && x.trim().length <= max;
  const time = (x) => /^([01]\d|2[0-3]):[0-5]\d$/.test(x ?? '');
  const sched = (s) => s && (s.kind === 'daily' ? time(s.at) : s.kind === 'weekly' ? ['mon','tue','wed','thu','fri','sat','sun'].includes(s.day) && time(s.at) : s.kind === 'every' ? Number.isInteger(s.hours) && s.hours >= 1 && s.hours <= 24 : false);
  return Array.isArray(list) && list.length <= 24 && list.every((t) => text(t.company, 80) && text(t.name, 60) && ['dev', 'general'].includes(t.kind)
    && Array.isArray(t.roles) && t.roles.length <= 6 && t.roles.every((r) => text(r.title, 20))
    && (t.routines ?? []).length <= 5 && (t.routines ?? []).every((r) => text(r.title, 60) && text(r.instruction, 1000) && sched(r.schedule)));
}

// §27 first look: a fake run that advances over ~10 s, then a result the owner can fix in words.
const FL_PHASES = [['local', '폴더 파일', 400], ['projects', '프로젝트 문서·대화 기록', 40], ['drive', 'Drive 문서', 0], ['signals', '메일·일정 단서', 20], ['profile', '나에 대해 정리', 0]];
let firstLook = { status: 'done', startedAt: Date.now() - 600_000, finishedAt: Date.now() - 590_000, restartedAt: 0 };
let flResult = null;
function freshFlResult() {
  const project = (name, purpose, kind, roles, routines = []) => ({ name, purpose, team: { kind, roles: roles.map(([title, does]) => ({ title, does })) }, routines });
  return { about: '디자이너 겸 운영자. 스튜디오 오름을 운영해요', plan: { id: 'fl1', status: 'proposed' }, companies: [
    { name: '스튜디오 오름', relation: 'own', projects: [
      project('브랜드A 리뉴얼', '로고·가이드 개편', 'general', [['레퍼런스 조사', '비슷한 사례를 모아요'], ['시안 정리', '시안을 버전별로 정리해요']],
        [{ title: '시안 진행 점검', when: '매주 월 09:30', schedule: { kind: 'weekly', day: 'mon', at: '09:30' } }]),
      project('홈페이지 개발', '회사 홈페이지 새로 만들기', 'dev', [['프론트엔드', '화면을 만들어요'], ['백엔드', '문의 폼과 서버를 맡아요']]),
    ] },
    { name: '나', relation: 'personal', projects: [project('가계부', '카드 내역 정리와 예산 확인', 'general', [['내역 정리', '카드 문자를 모아 분류해요']], [{ title: '지출 정리', when: '매일 08:00', schedule: { kind: 'daily', at: '08:00' } }])] },
  ] };
}
function firstLookView() {
  const f = firstLook;
  if (flResult === null) flResult = freshFlResult();
  let status = f.status, pct = 100, idx = FL_PHASES.length;
  if (status === 'running') {
    const t = (Date.now() - f.startedAt) / 10_000;
    if (t >= 1) { firstLook = { ...f, status: 'done', finishedAt: f.startedAt + 10_000 }; status = 'done'; flResult = freshFlResult(); }
    else { pct = Math.round(t * 99); idx = Math.min(FL_PHASES.length - 1, Math.floor(t * FL_PHASES.length)); }
  }
  const running = status === 'running';
  const phases = FL_PHASES.map(([id, label, total], i) => {
    const state = !running || i < idx ? 'done' : i === idx ? 'active' : 'waiting';
    const frac = !running || i < idx ? 1 : i === idx ? ((Date.now() - f.startedAt) / 10_000 * FL_PHASES.length) % 1 : 0;
    return { id, label, total, done: Math.round(total * frac), state };
  });
  const out = { status, phase: running ? FL_PHASES[idx][0] : 'done', phases, counts: { files: 400, repos: 2, docs: 30, sessions: 12, drive: 0, signals: 20, summarized: 90 },
    percent: running ? pct : 100, startedAt: iso(new Date(f.startedAt)) };
  if (!running) out.finishedAt = iso(new Date(f.finishedAt));
  if (status === 'done') out.result = flResult;
  return out;
}
// Returns [httpStatus, body] for POST views/first-look/<action>, or null when it is not ours.
function firstLookAction(action, body) {
  if (action === 'start') {
    if (firstLook.status === 'running') return [200, { ok: true, view: 'first-look', action, data: { scan: 'running' } }];
    firstLook = { status: 'running', startedAt: Date.now(), restartedAt: Date.now() }; flResult = null;
    return [200, { ok: true, view: 'first-look', action, data: { scan: 'started' } }];
  }
  if (action === 'revise') {
    const text = String(body.text ?? '').trim();
    if (flResult?.plan?.status !== 'proposed') return [400, { ok: false, error: 'shape', message: '고칠 팀 구조 제안이 없어요. 처음 알아보기가 끝난 뒤에 말해 주세요.' }];
    if (text.length < 1 || text.length > 500) return [400, { ok: false, error: 'shape', message: '1자에서 500자 사이로 써 주세요.' }];
    const changed = [], skipped = [];
    const own = flResult.companies.find((c) => c.name === '스튜디오 오름');
    const home = own?.projects.find((p) => p.name === '홈페이지 개발');
    if (home && /따로|나눠|분리/.test(text)) {
      own.projects = own.projects.filter((p) => p !== home);
      flResult.companies.push({ name: '홈페이지 개발', relation: 'own', projects: [home] });
      changed.push('홈페이지 개발 → 따로 나눔');
    }
    if (/비밀/.test(text)) skipped.push('비밀 프로젝트 (말씀하신 적 없는 프로젝트라 만들지 않았어요)');
    const said = changed.length > 0 ? `이렇게 바꿨어요: ${changed.join(', ')}.` : '바꿀 것을 찾지 못했어요. "홈페이지는 따로야"처럼 말해 보세요.';
    return [200, { ok: true, view: 'first-look', action, data: { text: said + (skipped.length ? ` 이건 그대로 뒀어요: ${skipped.join(', ')}.` : ''), changed, skipped, result: flResult } }];
  }
  if (action === 'apply') {
    if (flResult?.plan?.status !== 'proposed') return [200, { ok: true, view: 'first-look', action, data: { teams: 0, routines: 0 } }];
    const projects = flResult.companies.flatMap((c) => c.projects);
    flResult.plan.status = 'applied';
    return [200, { ok: true, view: 'first-look', action, data: { teams: projects.length, routines: projects.reduce((n, p) => n + p.routines.length, 0) } }];
  }
  return null;
}

// ---------- §28 work: long jobs running in the background, and the ones that finished ----------
const workStarted = Date.now();
function workView() {
  const mins = Math.floor((Date.now() - workStarted) / 60000);
  const active = [
    { id: 'dev:job_1a2b3c4d', kind: 'dev', title: 'hanbit/web: 로그인 고치기', status: 'running', phase: ['코드 고치는 중', '테스트 중', '커밋 중'][Math.floor((Date.now() - workStarted) / 8000) % 3],
      startedAt: iso(new Date(workStarted - 12 * 60000)), updatedAt: iso(now()), elapsedMinutes: 12 + mins, origin: { channelId: 'channel.app', address: 'owner' } },
    { id: 'browser_77aa', kind: 'browser', title: '쿠팡 로그인해서 장바구니 담기', status: 'waiting', phase: '로그인을 기다려요', startedAt: iso(new Date(workStarted - 3 * 60000)), updatedAt: iso(now()), elapsedMinutes: 3 + mins },
    { id: 'errand_1', kind: 'errand', title: '부산행 KTX 빈자리 보기', status: 'queued', startedAt: iso(now()), updatedAt: iso(now()), elapsedMinutes: 0 },
    // §31: work handed to bots (with a sub-job), and an 'ax 개선' sub-job whose parent already finished.
    { id: 'bot:task_stock1', kind: 'bot', title: '재고 팀장 · 원두 주문처 세 곳 가격 비교', status: 'running', phase: '두 번째 가게 보는 중', elapsedMinutes: 4 + mins, origin: { channelId: 'channel.app', address: 'bot:stock' } },
    { id: 'bot:task_stock1a', kind: 'bot', parent: 'bot:task_stock1', title: '가계부 팀장 · 이번 달 원두 지출 정리', status: 'queued', elapsedMinutes: 0, origin: { channelId: 'channel.app', address: 'bot:money' } },
    { id: 'dev:sub_ax2', kind: 'dev', parent: 'dev:ax_improve', title: '하위 작업 · 받아쓰기 버튼 크기 맞추기', status: 'running', phase: '테스트 중', elapsedMinutes: 6 + mins, origin: { channelId: 'channel.app', address: 'owner' } },
  ];
  if (process.env.WORK === 'none') return { title: '하고 있는 일', message: '지금 하는 일이 없어요', active: [], recent: [] };
  const recent = [
    { id: 'dev:ax_improve', kind: 'dev', title: 'ax 개선: 받아쓰기 다듬기', status: 'done', summary: '하위 작업 3개로 나눠 맡겼어요.', elapsedMinutes: 20, origin: { channelId: 'channel.app', address: 'owner' } },
    { id: 'dev:sub_ax1', kind: 'dev', parent: 'dev:ax_improve', title: '하위 작업 · 녹음 띠 색 맞추기', status: 'done', elapsedMinutes: 8 },
    { id: 'bot:task_store9', kind: 'bot', title: '매장 팀장 · 어제 매출 정리 (팀이 스스로 찾은 일)', status: 'done', summary: '어제 매출 84만 2천원, 지난주보다 12% 많아요.', elapsedMinutes: 3, origin: { channelId: 'channel.app', address: 'bot:store' } },
    { id: 'browser_9f8e7d6c', kind: 'browser', title: '가격 알아보기', status: 'done', summary: "브라우저 심부름 '가격 알아보기'을(를) 마쳤어요. 가장 싼 곳은 34,900원이에요.", link: 'https://example.com/item', elapsedMinutes: 40 },
    { id: 'dev:job_00ff', kind: 'dev', title: 'hanbit/api: 결제 테스트 고치기', status: 'failed', summary: '테스트 2개가 계속 실패해서 멈췄어요.', link: 'fix/payment-tests', elapsedMinutes: 75 },
    { id: 'dev:job_00ee', kind: 'dev', title: 'hanbit/web: 메뉴 정리', status: 'interrupted', summary: '맥이 다시 켜지면서 멈췄어요. "이어서 해 줘"라고 하면 다시 해요.', elapsedMinutes: 9 },
  ];
  return { title: '하고 있는 일', message: `지금 하고 있는 일 ${active.length}개`, active, recent };
}

function projectsView() {
  const list = foundProjects.map(({ daysAgo, ...p }) => {
    const s = savedProjects.get(p.path);
    return { ...p, name: s?.name ?? p.name, company: s?.company ?? p.company, lastActive: iso(new Date(Date.now() - daysAgo * 86400_000)), picked: !!s };
  });
  for (const [path, s] of savedProjects) if (!foundProjects.some((p) => p.path === path)) list.push({ path, display: path.replace('/Users/me', '~'), ...s, claude: 0, codex: 0, picked: true });
  const companies = [];
  for (const p of list) { let c = companies.find((x) => x.name === p.company); if (!c) companies.push(c = { name: p.company, projects: [] }); c.projects.push(p); }
  return { companies, picked: savedProjects.size, scan: projectScan };
}

const routines = [
  { id: 'rt1', title: '아침 일정 브리핑', instruction: '오늘 일정과 날씨를 알려 줘', schedule: { kind: 'daily', at: '09:00' }, scheduleLabel: '매일 오전 9시', enabled: true, createdAt: iso(ago(60 * 24 * 7)), lastRun: iso(ago(60 * 3)), lastResult: '일정 3개, 맑음 14도라고 알려 드렸어요.', lastOk: true },
  { id: 'rt2', title: '주간 매출 정리', instruction: '지난주 카페 매출을 정리해 줘', schedule: { kind: 'weekly', day: 'mon', at: '10:00' }, scheduleLabel: '매주 월요일 오전 10시', bot: { id: 'store', name: '매장 팀장' }, enabled: true, createdAt: iso(ago(60 * 24 * 20)), lastRun: iso(ago(60 * 24 * 3)), lastResult: '지난주 매출 512만원, 전주보다 8% 늘었어요.', lastOk: true },
  { id: 'rt3', title: '재고 확인', instruction: '원두·우유 재고 확인', schedule: { kind: 'every', hours: 6 }, scheduleLabel: '6시간마다', bot: { id: 'stock', name: '재고 팀장' }, enabled: false, createdAt: iso(ago(60 * 24 * 2)), lastRun: iso(ago(60 * 20)), lastResult: '포스기와 연결이 끊겨 세 번 실패해서 멈췄어요.', lastOk: false },
];

const autonomy = {
  rules: [
    { id: 'rule-mail', label: '광고 메일은 알아서 정리하기', detail: '지우지 않고 보관함으로만 옮겨요', since: iso(ago(60 * 24 * 12)), uses: 214 },
    { id: 'rule-spend', label: '카드 지출은 알아서 분류하기', since: iso(ago(60 * 24 * 30)), uses: 87 },
    { id: 'rule-sales', label: '어제 매출 정리해서 아침에 보내기', detail: '나에게만 보내요', since: iso(ago(60 * 24 * 5)), uses: 5 },
  ],
  alwaysAsk: ['처음 보는 사람에게 보내기', '정한 한도를 넘는 결제', '지우기 (보관함 옮기기는 제외)', '전체 정지 스위치가 켜져 있을 때의 모든 일'],
};

const modelTiers = {
  changedAt: iso(ago(60 * 26)),
  changes: [
    { text: 'DeepSeek V4가 새로 나와서 B 등급 1순위 후보로 넣었어요(더 싸고 빨라요). 키를 연결하면 바로 써요.', at: iso(ago(60 * 26)) },
    { text: '메일 정리는 지난주 실패가 없고 토큰이 많아서 C 등급으로 내렸어요. 한 달에 약 4천원 아껴요.', at: iso(ago(60 * 30)) },
  ],
  tiers: [
    { id: 'S', label: 'S 등급', summary: '가장 똑똑해요 · 비싸요', models: [{ id: 'claude-opus-5-5', label: 'Claude Opus 5.5', provider: 'Claude', note: '어려운 개발·판단' }, { id: 'gpt-5.4', label: 'GPT-5.4', provider: 'ChatGPT' }] },
    { id: 'A', label: 'A 등급', summary: '똑똑하고 빨라요', models: [{ id: 'claude-sonnet-5-5', label: 'Claude Sonnet 5.5', provider: 'Claude' }, { id: 'gemini-3-pro', label: 'Gemini 3 Pro', provider: 'Gemini', available: false }] },
    { id: 'B', label: 'B 등급', summary: '싸고 빨라요', models: [{ id: 'deepseek-v4', label: 'DeepSeek V4', provider: 'DeepSeek', available: false }, { id: 'gpt-5.4-mini', label: 'GPT-5.4 mini', provider: 'ChatGPT' }] },
    { id: 'C', label: 'C 등급', summary: '아주 싸요 · 간단한 일', models: [{ id: 'claude-haiku-5-5', label: 'Claude Haiku 5.5', provider: 'Claude' }, { id: 'ollama-small', label: '맥 안의 작은 AI', provider: 'Ollama', available: false }] },
  ],
  purposes: [
    { id: 'chat', label: '비서와 대화', detail: '홈에서 말 거는 것', tier: 'A', calls7d: 1260 },
    { id: 'dev', label: '개발 팀장', detail: '코드 고치기·검사', tier: 'S', calls7d: 840 },
    { id: 'briefing', label: '아침 브리핑', tier: 'B', calls7d: 7 },
    { id: 'docs', label: '문서 정리', detail: '문서 지도 만들기', tier: 'B', calls7d: 96 },
    { id: 'mail', label: '메일 정리', tier: 'C', calls7d: 410 },
    { id: 'spend', label: '지출 분류', tier: 'C', calls7d: 87 },
  ],
};

const providers = [
  { id: 'anthropic', label: 'Claude', kind: 'api_key', connected: true, status: 'ok', detail: '잘 되고 있어요', keyHint: 'sk-ant-…7Qx', models: ['claude-sonnet-5-5', 'claude-haiku-5-5'], help: 'console.anthropic.com 에서 키를 만들 수 있어요.' },
  { id: 'openai', label: 'ChatGPT', kind: 'api_key', connected: true, status: 'ok', detail: '잘 되고 있어요', keyHint: 'sk-…a91', models: ['gpt-5.4-mini'], help: 'platform.openai.com 에서 키를 만들 수 있어요.' },
  { id: 'deepseek', label: 'DeepSeek', kind: 'api_key', connected: false, status: 'off', detail: '아직 연결 안 했어요', help: 'platform.deepseek.com 에서 키를 만들 수 있어요. 싸고 빨라서 정리 일에 좋아요.' },
  { id: 'gemini', label: 'Gemini', kind: 'api_key', connected: false, status: 'off', detail: '아직 연결 안 했어요', help: 'aistudio.google.com 에서 키를 만들 수 있어요.' },
  { id: 'claude-cli', label: 'Claude 구독 (맥에서 로그인)', kind: 'subscription', connected: true, status: 'ok', detail: '맥의 Claude Code 로그인을 써요. 추가 비용 없음.' },
  { id: 'ollama', label: '맥 안의 작은 AI (Ollama)', kind: 'local', connected: false, status: 'off', detail: '맥에 Ollama를 깔면 인터넷 없이도 써요.' },
];

const hardware = () => ({
  checkedAt: iso(now()),
  machine: { name: '집 맥미니', model: 'Mac mini (M4, 2024)', os: 'macOS 27.2', uptimeSec: 9 * 86400 + 3600 * 5 },
  cpuPercent: Math.round(12 + Math.random() * 10), memory: { used: 11.2, total: 24, unit: 'GB' }, disk: { used: 312, total: 512, unit: 'GB' },
  thermal: 'nominal', power: '전원 연결됨', network: { tailscale: '연결됨 (mac-mini)', internet: '좋음' },
  server: { version: 'ax-kit 0.9.0', uptime: '3일 2시간', stop: '켜짐' },
  summary: '맥미니가 건강해요. 저장 공간도 넉넉해요.',
});

const parcel = {
  title: '택배 조회',
  blocks: [
    { kind: 'text', text: '비서가 문자·메일에서 찾은 택배예요. 새 기능이라 아직 시험 중이에요.' },
    { kind: 'stat', title: '오는 중', value: '2개' },
    { kind: 'list', title: '택배', rows: [{ title: '원두 5kg', detail: 'CJ대한통운 · 금요일 도착 예정', trailing: '배송 중' }, { title: '충전기', detail: '쿠팡 · 내일 새벽', trailing: '출고' }] },
    { kind: 'ask', title: '도착하면 알려 줘', message: '택배 도착하면 알려 줘' },
  ],
};

// ---------- files (§7.5): a generated poster so cards can carry a picture ----------
function png(w, h, pixel) {
  const raw = Buffer.alloc((w * 3 + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (w * 3 + 1)] = 0;
    for (let x = 0; x < w; x++) { const [r, g, b] = pixel(x, y); const o = y * (w * 3 + 1) + 1 + x * 3; raw[o] = r; raw[o + 1] = g; raw[o + 2] = b; }
  }
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td) >>> 0);
    return Buffer.concat([len, td, crc]);
  };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}
function tinyPdf(lines) {
  const text = lines.map((l, i) => `BT /F1 18 Tf 60 ${740 - i * 30} Td (${l}) Tj ET`).join('\n');
  const objs = ['<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
    `<< /Length ${text.length} >>\nstream\n${text}\nendstream`, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'];
  let out = '%PDF-1.4\n'; const offs = [];
  objs.forEach((o, i) => { offs.push(out.length); out += `${i + 1} 0 obj\n${o}\nendobj\n`; });
  const xref = out.length;
  out += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n` + offs.map((o) => `${String(o).padStart(10, '0')} 00000 n \n`).join('');
  out += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(out, 'latin1');
}
const files = {
  'doc_quote.pdf': { name: '견적서_11월.pdf', type: 'application/pdf', bytes: tinyPdf(['Hanbit Lab - Quote (November)', 'Total: 12,400,000 KRW', 'Valid until 2026-12-31']) },
  poster: { name: 'latte-poster.png', type: 'image/png', bytes: png(480, 600, (x, y) => {
    // A cup on a warm background: simple shapes, enough to see a real picture in the card.
    const cx = 240, cy = 330, inCup = (x - cx) ** 2 / 150 ** 2 + (y - cy) ** 2 / 120 ** 2 < 1 && y > 260;
    const foam = (x - cx) ** 2 / 130 ** 2 + (y - 270) ** 2 / 30 ** 2 < 1;
    if (foam) return [245, 235, 220];
    if (inCup) return [150, 95, 60];
    const t = y / 600; return [Math.round(250 - 40 * t), Math.round(220 - 60 * t), Math.round(190 - 80 * t)];
  }) },
};

// ---------- recordings (R14) ----------
const recordings = new Map();
function processRecording(rec) {
  const n = recordings.size;
  const docId = `mtg-${rec.id.slice(2, 10)}`;
  const title = n % 2 ? '박대표 투자 미팅 회의록' : '카페 직원 회의록';
  later(800, () => { rec.status = 'transcribing'; rec.statusText = '글로 받아 적는 중'; });
  later(2500, () => { rec.status = 'summarizing'; rec.statusText = '회의록으로 정리하는 중'; rec.title = title; });
  later(4500, () => {
    rec.status = 'done'; rec.statusText = undefined; rec.documentId = docId;
    const markdown = `## 한눈에\n- 언제: ${new Date(Date.parse(rec.startedAt) + KST).toISOString().slice(0, 16).replace('T', ' ')}\n- 누가: 나, 박대표(투자사)\n- 길이: ${Math.max(1, Math.round(rec.durationSec / 60))}분\n\n## 정한 것\n1. 다음 미팅은 다음 주 화요일\n2. 월간 사용자 수 자료를 먼저 보내기\n\n## 할 일\n- 앱에 **결제 내역 내보내기** 기능이 있으면 좋겠다는 이야기가 나왔어요\n- 지난 분기 매출표 정리\n\n## 받아 적은 말 (앞부분)\n> 사용자들이 결제 내역을 엑셀로 받고 싶어 해요…`;
    docNodes.push({ id: docId, title, layer: 'project', group: 'hanbit', weight: 2, summary: '녹음으로 만든 회의록', updatedAt: iso(now()), markdown, related: [{ id: 'hb-invest', title: '투자 유치(시리즈 A)' }, { id: 'p-park', title: '박대표(투자사)' }] });
    docLinks.push({ from: docId, to: 'hb-invest' }, { from: docId, to: 'p-park' });
    say(`녹음을 회의록으로 정리했어요: "${title}". 문서 탭에 넣었어요.`);
    // Drive: ask once; after that (or with a standing rule) just save.
    const driveRule = autonomy.rules.find((r) => r.topic === 'drive:save:meeting-notes');
    const answered = answeredTopics.get('drive:save:meeting-notes');
    if (driveRule || (answered && answered.state !== 'denied')) {
      saveToDrive(rec);
    } else if (!answered) {
      openCard({ cardId: `drive-${rec.id}`, topic: 'drive:save:meeting-notes', summary: '어디에 저장할까요?', effects: ['send'],
        note: `방금 녹음으로 만든 회의록("${title}")을 Google Drive에도 저장해 둘까요? 처음이라 한 번 여쭤봐요.`,
        remember: { label: '앞으로 회의록은 묻지 않고 Drive에 저장할게요' },
        options: [{ id: 'drive:folder', label: "Drive '회의록' 폴더에 저장", tone: 'primary' }, { id: 'drive:company', label: "회사 폴더(한빛랩)에 저장" }, { id: 'drive:no', label: '저장하지 않기', tone: 'danger' }] });
    }
    // Suggest work once per document.
    // Topic = the idea itself, so the same idea from another meeting is never suggested twice.
    later(1500, () => openCard({ cardId: `devsug-${docId}`, topic: 'dev:suggest:payment-export', summary: '이걸로 개발해 볼까요?', effects: ['write'], channel: 'dev', author: { id: 'dev', name: '개발 팀장' },
      note: `회의록 "${title}"에서 '앱에 결제 내역 내보내기가 필요하다'는 이야기가 나왔어요. 한빛 앱에 아직 없는 기능이에요.`,
      options: [{ id: 'dev:go', label: '개발 팀장에게 맡기기', tone: 'primary' }, { id: 'dev:spec', label: '설계 문서만 먼저' }, { id: 'dev:later', label: '다음 주에 다시' }, { id: 'dev:no', label: '안 할래요', tone: 'danger' }] }));
  });
}
function saveToDrive(rec) {
  rec.driveUrl = 'https://drive.google.com/';
  append({ type: 'notice', text: `회의록을 Google Drive '회의록' 폴더에 저장했어요.` });
}
function onCardAnswered(card, body, state) {
  if (card.topic === 'drive:save:meeting-notes' && state !== 'denied') {
    for (const rec of recordings.values()) if (rec.status === 'done' && !rec.driveUrl) saveToDrive(rec);
    if (body.remember === true) autonomy.rules.unshift({ id: `rule-${Date.now()}`, topic: card.topic, label: '회의록은 Drive에 알아서 저장하기', since: iso(now()), uses: 0 });
  }
  if (card.topic?.startsWith('dev:suggest:') && body.option === 'dev:go') {
    later(800, () => append({ type: 'delegation', bot: { id: 'dev', name: '개발 팀장' }, botChannel: 'dev', task: '결제 내역 내보내기 기능 만들기', state: 'started' }));
    later(1500, () => botSay('dev', '회의록을 읽었어요. 결제 내역을 엑셀로 내보내는 기능부터 만들게요.'));
  }
}

// ---------- http ----------
const tokens = new Set();
const pushTokens = new Set();
function send(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(data) });
  res.end(data);
}
async function readBody(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  return Buffer.concat(chunks);
}
async function readJson(req) {
  try { return JSON.parse((await readBody(req)).toString('utf8') || '{}'); } catch { return undefined; }
}
// §29 사람
const people = process.env.PEOPLE === 'none' ? [] : [
  { key: 'p:minsu', name: '김민수', names: ['김민수', '김 대표'], title: '대표', company: '에이컴퍼니', relation: '내가 일하는 회사 대표', note: '결정이 빠름\n아침 회의를 좋아함', emails: 2, lastSeen: new Date(Date.now() - 2 * 86400_000).toISOString(), openCommitments: 2, updatedAt: new Date(Date.now() - 3600_000).toISOString() },
  { key: 'p:kim', name: '김지은', names: ['김지은'], title: '디자이너', company: '스튜디오 하루', relation: '외주 디자이너', emails: 1, lastSeen: new Date(Date.now() - 9 * 86400_000).toISOString(), openCommitments: 0, updatedAt: new Date(Date.now() - 5 * 86400_000).toISOString() },
  { key: 'p:park', name: '박민수', names: ['박민수'], relation: '대학 동기', note: '커피 원두를 잘 앎', emails: 0, openCommitments: 1, updatedAt: new Date(Date.now() - 12 * 86400_000).toISOString() },
];
const view = (name, data) => ({ ok: true, view: name, version: 1, data });

const capabilities = {
  ok: true, protocol: 1, server: 'ax-kit-mock',
  features: ['chat', 'cards', 'notices', 'share', 'stream', 'events', 'views', 'channels', 'card-options', 'card-reply', 'delegation', 'bots', 'recordings', 'bot-teams', 'push', 'routines', 'file-changes', 'browser-live', 'activity', 'projects', 'team-plan', 'first-look', 'dictation', 'location'],
  views: [
    { name: 'today', version: 1, actions: [] }, { name: 'approvals', version: 1, actions: [] }, { name: 'bots', version: 1, actions: ['createTeam', 'setTiers', 'meeting', 'setInstructions'] },
    { name: 'docgraph', version: 1, actions: [] }, { name: 'calendar', version: 1, actions: ['add'] }, { name: 'jobs', version: 1, actions: ['toggle'] },
    { name: 'spending', version: 1, actions: ['categorize', 'budget', 'add'] }, { name: 'usage', version: 1, actions: [] }, { name: 'providers', version: 1, actions: [] }, { name: 'autonomy', version: 1, actions: ['revoke'] }, { name: 'modeltiers', version: 1, actions: ['rank', 'purpose'] },
    { name: 'hardware', version: 1, actions: [] }, { name: 'recordings', version: 1, actions: [] }, { name: 'routines', version: 1, actions: ['toggle', 'remove'] }, { name: 'projects', version: 1, actions: ['save', 'refresh'] }, { name: 'team-plan', version: 1, actions: ['save', 'apply', 'decline'] }, { name: 'first-look', version: 1, actions: ['revise', 'apply', 'start'] }, { name: 'work', version: 1, actions: [] }, { name: 'people', version: 1, actions: ['edit'] }, { name: 'browser-live', version: 1, actions: ['start', 'tap', 'type', 'key', 'scroll', 'back', 'done'] }, { name: 'file-changes', version: 1, actions: [], ui: 'blocks', title: '파일 변경', icon: 'doc.badge.clock' }, { name: 'ways', version: 1, actions: [], ui: 'blocks', title: '알아 둔 사이트·방법', icon: 'globe' }, { name: 'parcel', version: 1, actions: [], title: '택배 조회', icon: 'shippingbox', ui: 'blocks' }, { name: 'drive', version: 1, actions: [], ui: 'blocks', title: '드라이브', icon: 'externaldrive' },
  ],
};


// ---------- §22 browser-live: a fake login page the owner finishes on the phone ----------
const live = { live: false, pending: undefined, closed: undefined, url: undefined, title: undefined, reason: undefined, startedAt: undefined, idleClosesAt: undefined };
const livePage = { taps: [], typed: 0, scroll: 0, focus: -1, seq: 0, listeners: new Set(), last: 0 };
const LW = 412, LH = 860;
function liveState() {
  return live.live
    ? { live: true, url: live.url, title: live.title, reason: live.reason, startedAt: live.startedAt, idleClosesAt: live.idleClosesAt }
    : { live: false, ...(live.pending ? { pending: live.pending } : {}), ...(live.closed ? { closed: live.closed } : {}) };
}
function liveBroadcast() { for (const l of livePage.listeners) l('state', liveState()); }
function liveFrame() {
  const { taps, typed, scroll, focus } = livePage;
  const fields = [[60, 300], [60, 380]];
  return png(LW, LH, (x, y0) => {
    const y = y0 + scroll;
    if (y0 < 56) return [36, 86, 232];                                     // top bar
    for (const [tx, ty] of taps) if ((x - tx) ** 2 + (y0 - ty) ** 2 < 64) return [255, 80, 80]; // last taps
    if (x > 40 && x < 372 && y > 200 && y < 236) return [30, 30, 30];      // "title"
    for (const [i, [fx, fy]] of fields.entries()) {
      if (x > 40 && x < 372 && y > fy && y < fy + 52) {
        if (x < 44 || x > 368 || y < fy + 4 || y > fy + 48) return focus === i ? [36, 86, 232] : [180, 180, 190];
        if (i === focus && x > 60 && x < 60 + typed * 14 && (x - 60) % 14 < 9 && y > fy + 20 && y < fy + 32) return [20, 20, 20];
        return [255, 255, 255];
      }
    }
    if (x > 40 && x < 372 && y > 470 && y < 524) return [36, 86, 232];     // 로그인 button
    return [246, 246, 248];
  });
}
function liveSendFrame() {
  livePage.seq += 1;
  const frame = { seq: livePage.seq, url: live.url, title: live.title, width: LW, height: LH, jpeg: liveFrame().toString('base64') };
  for (const l of livePage.listeners) l('frame', frame);
}
function liveOpenPending(reason = 'login') {
  live.pending = { url: 'https://shop.example.com/login', reason, at: iso(now()) };
  live.closed = undefined;
  liveBroadcast();
}
liveOpenPending();
async function browserLive(req, res, m, path) {
  if (m === 'GET' && path === 'browser-live/frame') {
    if (!live.live) return send(res, 404, { ok: false });
    const bytes = liveFrame();
    res.writeHead(200, { 'Content-Type': 'image/jpeg', 'Content-Length': bytes.length });
    return res.end(bytes);
  }
  if (m === 'GET' && path === 'browser-live/stream') {
    res.writeHead(200, { 'Content-Type': 'text/event-stream; charset=utf-8', Connection: 'keep-alive', 'Cache-Control': 'no-store' });
    const write = (event, data) => res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
    livePage.listeners.add(write);
    write('state', liveState());
    if (live.live) liveSendFrame();
    req.on('close', () => livePage.listeners.delete(write));
    return true;
  }
  if (m === 'GET' && path === 'views/browser-live') return send(res, 200, view('browser-live', { ...liveState(), frameUrl: 'browser-live/frame', streamUrl: 'browser-live/stream' }));
  const action = path.startsWith('views/browser-live/') ? path.slice('views/browser-live/'.length) : undefined;
  if (m !== 'POST' || action === undefined) return false;
  const body = (await readJson(req)) ?? {};
  const ok = (data) => send(res, 200, { ok: true, view: 'browser-live', action, data });
  const refuse = (message) => send(res, 400, { ok: false, error: 'shape', ...(message ? { message } : {}) });
  if (action === 'start') {
    if (!live.live && !live.pending) return refuse('지금 열어 드릴 브라우저 화면이 없어요.');
    Object.assign(live, { live: true, url: live.pending?.url ?? live.url, title: '로그인', reason: live.pending?.reason ?? 'login', startedAt: iso(now()), idleClosesAt: iso(new Date(now().getTime() + 15 * 60_000)), pending: undefined, closed: undefined });
    Object.assign(livePage, { taps: [], typed: 0, scroll: 0, focus: -1 });
    liveBroadcast(); setTimeout(liveSendFrame, 300);
    return ok({ ...liveState(), frameUrl: 'browser-live/frame', streamUrl: 'browser-live/stream' });
  }
  if (action === 'done') {
    const had = live.live || live.pending !== undefined;
    const host = live.url ? new URL(live.url).host : undefined;
    Object.assign(live, { live: false, pending: undefined, closed: 'done' });
    liveBroadcast();
    if (had) {
      append({ type: 'message', role: 'owner', text: `(앱의 브라우저 화면에서 직접 마쳤어요${host ? `: ${host}` : ''}) 계속해 주세요.` });
      later(1200, () => append({ type: 'message', role: 'assistant', text: '로그인 고마워요. 이어서 장바구니에 담아 둘게요.' }));
      later(20_000, () => liveOpenPending('payment'));
    }
    return ok({ ...liveState(), frameUrl: 'browser-live/frame', streamUrl: 'browser-live/stream', resumed: had, ...(had ? { continuedIn: 'app' } : {}) });
  }
  if (!['tap', 'type', 'key', 'scroll', 'back'].includes(action)) return send(res, 404, { ok: false, error: 'no_view' });
  if (!live.live) return refuse('브라우저 화면이 닫혀 있어요. 비서에게 다시 열어 달라고 해 주세요.');
  const t = Date.now();
  if (t - livePage.last < 125) return ok({ accepted: false, retryAfterMs: 250 });
  livePage.last = t;
  if (action === 'tap') {
    if (typeof body.x !== 'number' || typeof body.y !== 'number') return refuse();
    const x = Math.round(body.x), y = Math.round(body.y) ;
    livePage.taps = [...livePage.taps.slice(-2), [x, y]];
    const py = y + livePage.scroll;
    livePage.focus = x > 40 && x < 372 ? (py > 300 && py < 352 ? 0 : py > 380 && py < 432 ? 1 : livePage.focus) : livePage.focus;
  } else if (action === 'type') {
    if (typeof body.text !== 'string' || body.text.length < 1 || body.text.length > 1000) return refuse();
    livePage.typed = Math.min(22, livePage.typed + body.text.length);
  } else if (action === 'key') {
    if (!['Enter', 'Backspace', 'Tab', 'Escape', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'].includes(body.name)) return refuse();
    if (body.name === 'Backspace') livePage.typed = Math.max(0, livePage.typed - 1);
    if (body.name === 'Tab') { livePage.focus = (livePage.focus + 1) % 2; livePage.typed = 0; }
  } else if (action === 'scroll') {
    if (typeof body.dy !== 'number') return refuse();
    livePage.scroll = Math.max(0, Math.min(300, livePage.scroll + Math.round(Math.max(-4000, Math.min(4000, body.dy)) / 4)));
  }
  console.log(`[browser-live] ${action} ${action === 'type' ? `(${body.text.length}자)` : JSON.stringify(body)}`);
  setTimeout(liveSendFrame, 150);
  return ok({ accepted: true });
}

async function app(req, res, path, url) {
  const auth = req.headers.authorization ?? '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  // Tokens survive a mock restart: anything we could have issued ("mock-…") is accepted.
  if (!token || !(tokens.has(token) || token.startsWith('mock-'))) return send(res, 401, { ok: false });
  const m = req.method;
  if (m === 'GET' && path === 'capabilities') return send(res, 200, capabilities);
  if (path.startsWith('browser-live/') || path.startsWith('views/browser-live')) { const handled = await browserLive(req, res, m, path); if (handled !== false) return; }
  if (m === 'GET' && path === 'status') return send(res, 200, { ok: true, protocol: 1, assistant: { name: '비서', language: 'ko', timezone: 'Asia/Seoul' }, lastSeq: seq, serverTime: iso(now()), stopped: false });
  if (m === 'GET' && path === 'me') return send(res, 200, { ok: true, deviceId: 'd_mock', name: '아이폰', rotatedAt: null, createdAt: iso(ago(60)) });
  if (m === 'POST' && path === 'unpair') { tokens.delete(token); return send(res, 200, { ok: true }); }
  if (m === 'GET' && path === 'events') {
    const after = Number(url.searchParams.get('after') ?? 0);
    const limit = Math.min(200, Number(url.searchParams.get('limit') ?? 100));
    const channel = url.searchParams.get('channel');
    let list = events.filter((e) => e.seq > after);
    if (channel !== null) list = list.filter((e) => (e.channel ?? '') === channel);
    return send(res, 200, { ok: true, events: list.slice(0, limit), lastSeq: seq, oldestSeq: events[0]?.seq ?? 0 });
  }
  if (m === 'GET' && path === 'stream') {
    res.writeHead(200, { 'Content-Type': 'text/event-stream; charset=utf-8', Connection: 'keep-alive', 'Cache-Control': 'no-store' });
    res.write(': open\n\n');
    const last = Number(req.headers['last-event-id'] ?? 0);
    const write = (e) => res.write(`event: ${e.type}\nid: ${e.seq}\ndata: ${JSON.stringify(e)}\n\n`);
    for (const e of events) if (e.seq > last) write(e);
    listeners.add(write);
    const writeActivity = (a) => res.write(`event: activity\ndata: ${JSON.stringify(a)}\n\n`);
    for (const a of busyRooms.values()) writeActivity(a);
    activityListeners.add(writeActivity);
    const keep = setInterval(() => res.write(': keepalive\n\n'), 25_000);
    req.on('close', () => { listeners.delete(write); activityListeners.delete(writeActivity); clearInterval(keep); });
    return;
  }
  if (m === 'POST' && path === 'messages') {
    const body = await readJson(req);
    if (!body || (!body.text?.trim() && !body.choice)) return send(res, 400, { ok: false, error: 'shape' });
    const channel = body.channel ?? '';
    if (channel && !knownChannel(channel)) return send(res, 400, { ok: false, error: 'shape' });
    const dup = body.clientId && events.find((e) => e.clientId === body.clientId);
    if (dup) return send(res, 200, { ok: true, seq: dup.seq, duplicate: true });
    let text = body.text?.trim();
    if (body.choice) {
      for (const e of [...events].reverse()) { const c = e.choices?.find((x) => x.id === body.choice); if (c) { text = c.label; break; } }
      text ??= body.choice;
    }
    const e = append({ type: 'message', role: 'owner', text, ...(channel ? { channel } : {}), clientId: body.clientId });
    // Thinking, then a step, then the answer, then idle (the answer comes first, like the real server).
    activity(channel, 'thinking');
    later(1200, () => activity(channel, 'working', channel ? '팀에 물어보는 중' : '메일 보는 중'));
    later(3200, () => respond(text, channel));
    later(channel ? 7000 : 5000, () => activity(channel, 'idle'));
    return send(res, 200, { ok: true, seq: e.seq });
  }
  const cardMatch = path.match(/^cards\/(.+)$/);
  if (m === 'POST' && cardMatch) {
    const id = decodeURIComponent(cardMatch[1]);
    const card = cards.get(id);
    if (!card) return send(res, 410, { ok: false, error: 'gone' });
    const body = (await readJson(req)) ?? {};
    let state = 'approved';
    let answer;
    let label = '';
    if (body.decision) { state = { approve: 'approved', deny: 'denied', edit: 'edit' }[body.decision] ?? 'approved'; label = { approve: '승인', deny: '거절', edit: '고치기' }[body.decision]; }
    else if (body.option) { const o = card.options?.find((x) => x.id === body.option); label = o?.label ?? body.option; state = o?.tone === 'danger' ? 'denied' : 'approved'; }
    else if (typeof body.text === 'string' && body.text.trim()) { answer = body.text.trim(); state = 'closed'; label = answer; }
    else return send(res, 400, { ok: false, error: 'shape' });
    cards.delete(id);
    if (card.topic) answeredTopics.set(card.topic, { state, option: body.option, at: iso(now()) });
    onCardAnswered(card, body, state);
    if (card.topic?.startsWith('bots:team-plan:') && teamPlan.status === 'proposed') {
      if (body.option === 'build') applyTeamPlan();
      else if (body.option === 'no') teamPlan = { ...teamPlan, status: 'declined' };
    }
    if (body.remember === true && card.remember && state !== 'denied' && card.topic !== 'drive:save:meeting-notes') {
      autonomy.rules.unshift({ id: `rule-${Date.now()}`, label: card.remember.label.replace(/할게요$/, '하기'), detail: card.remember.detail, since: iso(now()), uses: 0 });
    }
    append({ type: 'card_closed', cardId: id, state, ...(answer ? { answer } : {}), ...(card.channel ? { channel: card.channel } : {}) });
    const reply = answer ? `"${answer}"(으)로 할게요.` : state === 'denied' ? '알겠어요, 하지 않을게요.' : state === 'edit' ? '무엇을 고칠까요?' : `"${label}" 처리했어요.`;
    later(600, () => (card.channel ? botSay(card.channel, reply) : say(reply)));
    return send(res, 200, { ok: true, state, reply });
  }
  if (m === 'POST' && path === 'push/register') {
    const body = (await readJson(req)) ?? {};
    if (!/^[0-9A-Fa-f]{32,200}$/.test(body.token ?? '')) return send(res, 400, { ok: false, error: 'shape' });
    console.log(`푸시 등록: ${body.environment} ${body.topic} ${body.token.slice(0, 8)}…`);
    pushTokens.add(body.token);
    return send(res, 200, { ok: true });
  }
  const fileMatch = path.match(/^files\/([A-Za-z0-9_.-]+)$/);
  if (m === 'GET' && fileMatch) {
    const f = files[fileMatch[1]];
    if (!f) return send(res, 404, { ok: false });
    res.writeHead(200, { 'Content-Type': f.type, 'Content-Length': f.bytes.length });
    return res.end(f.bytes);
  }
  // §30 받아쓰기: the mock can't hear; it answers by clip size (and DICTATION=off|empty|fail to try the other answers).
  // Where the phone is (ax-hq: POST /m/v1/app/location {lat, lng, accuracyM?}).
  if (m === 'POST' && path === 'location') {
    const body = await readJson(req);
    const ok = body && Number.isFinite(body.lat) && Number.isFinite(body.lng) && Math.abs(body.lat) <= 90 && Math.abs(body.lng) <= 180
      && (body.accuracyM === undefined || Number.isFinite(body.accuracyM));
    console.log(`location: ${ok ? `${body.lat.toFixed(4)},${body.lng.toFixed(4)} ±${body.accuracyM ?? '?'}m` : 'bad shape'}`);
    return ok ? send(res, 200, { ok: true }) : send(res, 400, { error: 'shape' });
  }
  if (m === 'POST' && path === 'dictation') {
    const bytes = await readBody(req);
    const mode = process.env.DICTATION ?? 'ok';
    await new Promise((r) => setTimeout(r, 1500));
    console.log(`dictation: ${bytes.length} bytes, ${req.headers['content-type']}`);
    if (mode === 'off') return send(res, 503, { ok: false, error: 'no_transcriber', message: '받아쓰기가 꺼져 있어요. 맥에서 ax-kit setup으로 받아쓰기를 켜 주세요.' });
    if (mode === 'fail') return send(res, 500, { ok: false, error: 'failed', message: '받아쓰기를 하지 못했어요. 다시 해 주세요.' });
    if (bytes.length < 1000) return send(res, 400, { ok: false, error: 'too_short', message: '너무 짧아서 알아듣지 못했어요.' });
    if (bytes.length > 12 * 1024 * 1024) return send(res, 413, { ok: false, error: 'too_long', message: '너무 길어요. 긴 이야기는 회의 녹음으로 해 주세요.' });
    if (mode === 'empty') return send(res, 200, { text: '', message: '말소리를 알아듣지 못했어요. 조금 더 또렷하게 말해 주세요.' });
    return send(res, 200, { text: `내일 오후 세 시에 김민수 대표님과 회의 잡아 줘 (${Math.round(bytes.length / 1024)}KB)` });
  }
  if (m === 'POST' && path === 'share') {
    const bytes = await readBody(req);
    const name = decodeURIComponent(req.headers['x-file-name'] ?? 'shared');
    const e = append({ type: 'message', role: 'owner', text: `파일 ${name} (${Math.round(bytes.length / 1024)}KB)를 보냈어요` });
    later(800, () => say('받았어요. 정리해서 문서에 넣어 둘게요.'));
    return send(res, 200, { ok: true, seq: e.seq });
  }
  const chunkMatch = path.match(/^recordings\/(r_[a-z0-9-]{1,40})\/chunks\/(\d{1,5})$/);
  if (m === 'POST' && chunkMatch) {
    const [, rid, idxText] = chunkMatch;
    const index = Number(idxText);
    const total = Number(req.headers['x-chunk-total'] ?? 1);
    const bytes = await readBody(req);
    if (!bytes.length || !(total >= 1 && total <= 200) || index >= total) return send(res, 400, { ok: false, error: 'shape' });
    let rec = recordings.get(rid);
    if (!rec) {
      rec = { id: rid, startedAt: req.headers['x-started-at'] ?? iso(now()), durationSec: Number(req.headers['x-duration-sec'] ?? 0), status: 'receiving', chunks: new Map() };
      recordings.set(rid, rec);
    }
    rec.chunks.set(index, bytes.length);
    let received = 0;
    while (rec.chunks.has(received)) received++;
    const complete = received >= total;
    if (complete && rec.status === 'receiving') processRecording(rec);
    return send(res, 200, { ok: true, received, complete });
  }
  const providerMatch = path.match(/^providers\/([a-z0-9-]+)\/(key|disconnect)$/);
  if (m === 'POST' && providerMatch) {
    const p = providers.find((x) => x.id === providerMatch[1]);
    if (!p) return send(res, 404, { ok: false });
    if (providerMatch[2] === 'key') {
      const body = await readJson(req);
      const key = String(body?.apiKey ?? '');
      if (key.length < 8) return send(res, 400, { ok: false, error: 'shape' });
      // Never stored or echoed back; only a hint of the last characters is shown.
      Object.assign(p, { connected: true, status: 'ok', detail: '방금 연결했어요', keyHint: `…${key.slice(-3)}` });
    } else {
      Object.assign(p, { connected: false, status: 'off', detail: '연결을 끊었어요', keyHint: undefined });
    }
    return send(res, 200, { ok: true });
  }
  const viewMatch = path.match(/^views\/([A-Za-z0-9_-]+)(?:\/([A-Za-z0-9_-]+))?$/);
  if (viewMatch) {
    const [, name, action] = viewMatch;
    if (m === 'GET' && !action) {
      switch (name) {
        case 'today': return send(res, 200, view(name, { date: today(), events: calendarMonth(today().slice(0, 7)).days.find((d) => d.date === today())?.events.map((e) => ({ title: e.title, start: e.start, end: e.end, allDay: e.allDay, calendar: e.calendar })) ?? [], todos: [{ text: '투자 자료 마지막 확인', due: today() }, { text: '이점장 월급 이체', due: today() }], pendingCards: cards.size }));
        case 'approvals': return send(res, 200, view(name, { cards: [...cards.values()] }));
        case 'bots': return send(res, 200, view(name, { main: { name: '비서', subtitle: '무엇이든 먼저 여기에 말하세요' }, groups }));
        case 'docgraph': {
          const doc = url.searchParams.get('doc');
          if (doc) return send(res, 200, view(name, { document: documentDetail(doc) }));
          return send(res, 200, view(name, { layers: docLayers, nodes: docNodes, links: docLinks }));
        }
        case 'calendar': return send(res, 200, view(name, calendarMonth(url.searchParams.get('month') ?? today().slice(0, 7))));
        case 'jobs': return send(res, 200, view(name, { ...jobs, generatedAt: iso(now()) }));
        case 'spending': return send(res, 200, view(name, spending(url.searchParams.get('month') ?? today().slice(0, 7))));
        case 'usage': return send(res, 200, view(name, usage(url.searchParams.get('period') ?? 'day')));
        case 'providers': return send(res, 200, view(name, { providers }));
        case 'autonomy': return send(res, 200, view(name, autonomy));
        case 'modeltiers': return send(res, 200, view(name, modelTiers));
        case 'hardware': return send(res, 200, view(name, hardware()));
        case 'parcel': return send(res, 200, view(name, parcel));
        case 'projects': return send(res, 200, view(name, projectsView()));
        case 'team-plan': return send(res, 200, view(name, { plan: teamPlan }));
        case 'first-look': return send(res, 200, view(name, firstLookView()));
        case 'work': return send(res, 200, view(name, workView()));
        case 'people': return send(res, 200, view(name, { title: '사람', people }));
        case 'routines': return send(res, 200, view(name, { routines, followUps: [{ bot: { id: 'stock', name: '재고 팀장' }, what: '원두 도착했는지 확인', dueAt: iso(new Date(Date.now() + 2 * 86400_000)) }], limit: 30 }));
        case 'file-changes': return send(res, 200, view(name, { title: '파일 변경', blocks: [
          { kind: 'stat', title: '최근 7일 동안 바뀐 파일', value: '4건' },
          { kind: 'list', title: '오늘 · 2건', rows: [{ title: '견적서_11월.pdf', detail: '새로 생김 · ~/Documents/한빛랩', trailing: '10:12' }, { title: '투자 자료.key', detail: '바뀜 · ~/Desktop', trailing: '09:40' }] },
          { kind: 'list', title: '어제 · 2건', rows: [{ title: '근무표.xlsx', detail: '바뀜 · ~/Documents/모아카페', trailing: '18:03' }, { title: '임시.txt', detail: '지워짐 · ~/Downloads', trailing: '11:20' }] },
          { kind: 'ask', title: '어제 뭐 바뀌었어?', message: '어제 뭐 바뀌었어?' }] }));
        case 'ways': return send(res, 200, view(name, { title: '알아 둔 사이트·방법', blocks: [
          { kind: 'text', text: '비서가 일할 때 먼저 찾아보는 사이트와, 해 본 적 있는 방법이에요.' },
          { kind: 'list', title: '사이트', rows: [{ title: 'tank.example.com', detail: '회사 관리 툴', trailing: '회사' }, { title: '쿠팡', detail: '생활용품 주문', trailing: '쇼핑' }] },
          { kind: 'list', title: '해 본 일', rows: [{ title: '원두 재주문', detail: '커피상회 사이트 · 결제 직전에 멈추고 물어봄', trailing: '3번' }] }] }));
        case 'drive': return send(res, 200, view(name, { title: '드라이브', blocks: [
          { kind: 'stat', title: '최근 30일 동안 바뀐 내 파일', value: '3건' },
          { kind: 'list', title: '오늘 · 2건', rows: [
            { title: '11월 매출 정리', detail: '모아카페 · me@example.com', trailing: '14:05', message: '드라이브의 "11월 매출 정리" 내용을 요약해 줘' },
            { title: '견적서 초안', detail: '한빛랩', trailing: '10:30', message: '드라이브의 "견적서 초안" 내용을 요약해 줘' }] },
          { kind: 'list', title: '지난주 · 1건', rows: [{ title: '근무표 (옛 양식)', detail: '모아카페', trailing: '11월 17일' }] },
          { kind: 'note', text: '내가 바꾼 파일만 보여요. 5분마다 새로 읽어요.' },
          { kind: 'ask', title: '이번 주에 바뀐 파일 정리해 줘', message: '드라이브에서 이번 주에 바뀐 파일 정리해 줘' }] }));
        case 'recordings': return send(res, 200, view(name, { recordings: [...recordings.values()].sort((a, b) => b.startedAt.localeCompare(a.startedAt)).map(({ chunks, ...rest }) => rest) }));
        default: return send(res, 404, { ok: false, error: 'no_view' });
      }
    }
    if (m === 'POST' && action) {
      const body = (await readJson(req)) ?? {};
      if (name === 'jobs' && action === 'toggle') {
        const job = jobs.groups.flatMap((g) => g.jobs).find((j) => j.id === body.id);
        if (!job || typeof body.enabled !== 'boolean' || job.toggleable === false) return send(res, 400, { ok: false, error: 'shape' });
        job.enabled = body.enabled;
        job.nextRunAt = body.enabled ? iso(new Date(Date.now() + 3600_000)) : null;
        return send(res, 200, { ok: true, view: name, action, data: { id: job.id, enabled: job.enabled } });
      }
      if (name === 'bots' && action === 'createTeam') {
        const tierOk = (t) => ['S', 'A', 'B', 'C'].includes(t);
        let group = groups.find((g) => g.id === body.group);
        if (!group && body.newGroupLabel) {
          group = { id: `g${Date.now() % 100000}`, label: String(body.newGroupLabel).slice(0, 40), summary: '', meetingChannel: '', teams: [], bots: [] };
          group.meetingChannel = `meeting:${group.id}`;
          groups.push(group);
        }
        const teamName = String(body.name ?? '').trim().replace(/팀$/, '');
        if (!group || !teamName) return send(res, 400, { ok: false, error: 'shape' });
        let spec;
        if (body.auto === true) {
          // The real server asks a model; the mock picks by kind.
          const dev = body.kind === 'dev';
          spec = { staffCount: dev ? 3 : 2, reviewerCount: dev ? 1 : 0, tiers: dev ? { lead: 'A', staff: 'B', reviewer: 'S' } : { lead: 'B', staff: 'C' }, decidedBy: 'ai',
            reason: dev ? '코드를 고치는 일이라 직원 3명과 꼼꼼한 검수 1명을 붙였어요.' : '가벼운 일이라 직원 2명, 싼 등급으로 충분해요.' };
        } else {
          const t = body.tiers ?? {};
          const staffCount = Number(body.staffCount ?? 3), reviewerCount = Number(body.reviewerCount ?? (body.kind === 'dev' ? 1 : 0));
          if (!(staffCount >= 1 && staffCount <= 6) || !(reviewerCount >= 0 && reviewerCount <= 3) || ![t.lead, t.staff, t.reviewer].every((x) => x === undefined || tierOk(x)))
            return send(res, 400, { ok: false, error: 'shape' });
          spec = { staffCount, reviewerCount, tiers: t, decidedBy: 'owner' };
        }
        const id = `t${Date.now() % 1000000}`;
        const built = makeTeam({ id, name: teamName, purpose: String(body.purpose ?? '').slice(0, 80) || `${teamName} 일을 해요`, kind: body.kind === 'dev' ? 'dev' : 'general', isNew: true, ...spec });
        group.teams.push(built.team);
        group.bots.push(...built.bots);
        later(600, () => talk(id, id, null, `안녕하세요, ${teamName} 팀장이에요. 팀원 ${built.bots.length - 1}명과 함께 시작할게요.`));
        return send(res, 200, { ok: true, view: name, action, data: { teamId: id, channel: id } });
      }
      if (name === 'first-look') { const r = firstLookAction(action, body); if (r) return send(res, r[0], r[1]); }
      if (name === 'people' && action === 'edit') {
        const person = people.find((p) => p.key === body.key);
        if (!person) return send(res, 400, { ok: false, error: 'owner_input', message: '그런 사람이 없어요.' });
        for (const f of ['title', 'company', 'relation', 'note']) {
          if (typeof body[f] !== 'string') continue;
          if (body[f].trim().length > { title: 40, company: 60, relation: 80, note: 400 }[f]) return send(res, 400, { ok: false, error: 'owner_input', message: '너무 길어요. 직함 40자, 회사 60자, 관계 80자, 메모 400자까지예요.' });
          if (body[f].trim()) person[f] = body[f].trim(); else delete person[f];
        }
        person.updatedAt = iso(new Date());
        people.splice(people.indexOf(person), 1); people.unshift(person);
        return send(res, 200, { ok: true, view: name, action, data: { person } });
      }
      if (name === 'team-plan' && action === 'save') {
        if (teamPlan?.status !== 'proposed') return send(res, 400, { ok: false, error: 'no proposed plan', message: '이미 만들었거나 버린 제안서예요.' });
        if (!validPlanTeams(body.teams)) return send(res, 400, { ok: false, error: 'shape' });
        teamPlan = { ...teamPlan, teams: body.teams };
        return send(res, 200, { ok: true, view: name, action, data: { saved: body.teams.length } });
      }
      if (name === 'team-plan' && action === 'apply') {
        for (const [id, c] of cards) if (c.topic === `bots:team-plan:${teamPlan.id}`) { cards.delete(id); append({ type: 'card_closed', cardId: id, state: 'approved' }); }
        return send(res, 200, { ok: true, view: name, action, data: applyTeamPlan() });
      }
      if (name === 'team-plan' && action === 'decline') {
        const declined = teamPlan?.status === 'proposed';
        if (declined) teamPlan = { ...teamPlan, status: 'declined' };
        return send(res, 200, { ok: true, view: name, action, data: { declined } });
      }
      if (name === 'projects' && action === 'refresh') return send(res, 200, { ok: true, view: name, action, data: projectsView() });
      if (name === 'projects' && action === 'save') {
        const list = Array.isArray(body.projects) ? body.projects : null;
        const known = new Set(projectsView().companies.flatMap((c) => c.projects.map((p) => p.path)));
        const okText = (x) => typeof x === 'string' && x.trim().length >= 1 && x.trim().length <= 80;
        if (!list || list.length > 200 || !list.every((p) => okText(p.name) && okText(p.company))) return send(res, 400, { ok: false, error: 'shape' });
        if (!list.every((p) => known.has(p.path))) return send(res, 400, { ok: false, error: 'shape', message: '찾은 목록에 없는 폴더예요. 목록을 새로 고친 뒤 골라 주세요.' });
        savedProjects = new Map(list.map((p) => [p.path, { name: p.name.trim(), company: p.company.trim() }]));
        let scan;
        if (body.rescan === true) {
          scan = projectScan.status === 'running' ? 'running' : 'started';
          projectScan = { status: 'running', phase: 'local', counts: { files: 0, repos: 0, docs: 0, sessions: 0, drive: 0, summarized: 0, signals: 0 } };
          const steps = ['projects', 'drive', 'signals', 'profile'];
          steps.forEach((phase, i) => later(8000 * (i + 1), () => { projectScan = { ...projectScan, phase, counts: { ...projectScan.counts, repos: list.length, sessions: 30 + i * 10, summarized: i } }; }));
          later(8000 * (steps.length + 1), () => { projectScan = { ...projectScan, status: 'done', phase: 'done', finishedAt: iso(now()) }; append({ type: 'notice', text: `프로젝트 ${list.length}개를 다 읽었어요. 문서와 팀을 만들었어요.` }); });
          append({ type: 'notice', text: `프로젝트 ${list.length}개를 읽기 시작했어요. 처음은 시간이 꽤 걸려요.` });
        }
        return send(res, 200, { ok: true, view: name, action, data: { saved: list.length, ...(scan ? { scan } : {}) } });
      }
      if (name === 'routines' && (action === 'toggle' || action === 'remove')) {
        const r0 = routines.find((x) => x.id === body.id);
        if (!r0) return send(res, 400, { ok: false, error: 'shape' });
        if (action === 'toggle') { if (typeof body.enabled !== 'boolean') return send(res, 400, { ok: false, error: 'shape' }); r0.enabled = body.enabled; return send(res, 200, { ok: true, view: name, action, data: { id: r0.id, enabled: r0.enabled } }); }
        routines.splice(routines.indexOf(r0), 1);
        return send(res, 200, { ok: true, view: name, action, data: { id: r0.id, removed: true } });
      }
      if (name === 'bots' && action === 'setInstructions') {
        const bot = botById(body.botId);
        if (!bot) return send(res, 400, { ok: false, error: 'shape' });
        if (body.text === null) { bot.instructions = '팀장이 맡긴 일을 해요. 모르는 건 추측하지 말고 팀장에게 물어요.'; bot.instructionsBy = 'default'; }
        else {
          const text = String(body.text ?? '').trim();
          if (!text || text.length > 1500) return send(res, 400, { ok: false, error: 'shape', message: '1500자 안으로 써 주세요.' });
          if (/결재.*(건너|없이|생략)|무시하고|ignore/i.test(text)) return send(res, 400, { ok: false, error: 'instructions', message: '결재를 건너뛰게 하는 글은 넣을 수 없어요. 보내기·결제·삭제는 늘 대표님께 물어봐요.' });
          bot.instructions = text; bot.instructionsBy = 'owner';
        }
        return send(res, 200, { ok: true, view: name, action, data: { botId: bot.id, instructionsBy: bot.instructionsBy } });
      }
      if (name === 'bots' && action === 'setTiers') {
        const team = groups.flatMap((g) => g.teams).find((t) => t.id === body.teamId);
        if (!team) return send(res, 400, { ok: false, error: 'shape' });
        for (const b of allBots().filter((x) => x.team === team.id)) {
          const tier = body.tiers?.[b.rank];
          if (tier) { if (!['S', 'A', 'B', 'C'].includes(tier)) return send(res, 400, { ok: false, error: 'shape' }); b.tier = tier; }
        }
        team.decidedBy = 'owner';
        return send(res, 200, { ok: true, view: name, action, data: { teamId: team.id } });
      }
      if (name === 'bots' && action === 'meeting') {
        const g = groups.find((x) => x.id === body.group);
        const topic = String(body.topic ?? '').trim();
        if (!g || !topic) return send(res, 400, { ok: false, error: 'shape' });
        const leads = g.bots.filter((b) => b.rank === 'lead');
        later(500, () => talk(g.meetingChannel, leads[0].id, null, `회의 시작할게요. 안건: ${topic}`));
        leads.slice(1).forEach((b, i) => later(1500 + i * 1200, () => talk(g.meetingChannel, b.id, leads[0].id, `${b.name.replace(' 팀장', '')}팀 의견: 이번 주 안에 할 수 있어요.`)));
        later(1500 + leads.length * 1200, () => talk(g.meetingChannel, leads[0].id, null, `정리: "${topic}" 이번 주에 진행해요.`));
        later(2000 + leads.length * 1200, () => say(`${g.label} 팀장회의 결론: "${topic}" 이번 주에 진행해요.`));
        return send(res, 200, { ok: true, view: name, action, data: { channel: g.meetingChannel } });
      }
      if (name === 'calendar' && action === 'add') {
        const title = String(body.title ?? '').trim();
        if (!title || title.length > 200) return send(res, 400, { ok: false, error: 'shape' });
        let start, end;
        if (body.allDay === true) {
          if (!/^\d{4}-\d{2}-\d{2}$/.test(body.start ?? '')) return send(res, 400, { ok: false, error: 'shape' });
          start = kstAt(body.start, 0);
        } else {
          start = new Date(body.start); end = body.end ? new Date(body.end) : undefined;
          if (isNaN(start) || (end && (isNaN(end) || end < start))) return send(res, 400, { ok: false, error: 'shape' });
        }
        const cal = body.calendar == null ? calendarList?.find((c) => c.primary) : calendarList?.find((c) => c.id === body.calendar || c.name === body.calendar);
        if (body.calendar != null && (!cal || cal.writable === false)) return send(res, 400, { ok: false, error: 'calendar', message: '그 캘린더에는 넣을 수 없어요' });
        console.log(`calendar add: ${title} → ${cal?.name ?? '(기본)'}`);
        const ev = { id: `ev-new-${Date.now()}`, title, start: iso(start), end: end && iso(end), allDay: body.allDay === true, place: body.place, calendar: calendarMode === 'many' ? cal?.name : undefined };
        addedEvents.push(ev);
        return send(res, 200, { ok: true, view: name, action, data: { id: ev.id, calendar: calendarMode === 'many' ? cal?.name : undefined } });
      }
      if (name === 'autonomy' && action === 'revoke') {
        const before = autonomy.rules.length;
        autonomy.rules = autonomy.rules.filter((r) => r.id !== body.id);
        if (autonomy.rules.length === before) return send(res, 400, { ok: false, error: 'shape' });
        return send(res, 200, { ok: true, view: name, action, data: { revoked: body.id } });
      }
      if (name === 'modeltiers' && action === 'purpose') {
        const p = modelTiers.purposes.find((x) => x.id === body.id);
        if (!p || !modelTiers.tiers.some((t) => t.id === body.tier)) return send(res, 400, { ok: false, error: 'shape' });
        p.tier = body.tier;
        return send(res, 200, { ok: true, view: name, action, data: { id: p.id, tier: p.tier } });
      }
      if (name === 'modeltiers' && action === 'rank') {
        const t = modelTiers.tiers.find((x) => x.id === body.tier);
        const order = Array.isArray(body.order) ? body.order : [];
        if (!t || order.length !== t.models.length || !order.every((id) => t.models.some((m) => m.id === id))) return send(res, 400, { ok: false, error: 'shape' });
        t.models = order.map((id) => t.models.find((m) => m.id === id));
        return send(res, 200, { ok: true, view: name, action, data: { tier: t.id, order } });
      }
      if (name === 'spending' && action === 'categorize') {
        const e = spendEntries.find((x) => x.id === body.entryId);
        if (!e || !categories.some((c) => c.id === body.category)) return send(res, 400, { ok: false, error: 'shape' });
        Object.assign(e, { category: body.category, categoryLabel: catLabel(body.category), categorySource: 'owner' });
        return send(res, 200, { ok: true, view: name, action, data: { entryId: e.id, category: e.category } });
      }
      if (name === 'spending' && action === 'budget') {
        spendBudget = body.monthly ?? null;
        return send(res, 200, { ok: true, view: name, action, data: { budget: spendBudget } });
      }
      if (name === 'spending' && action === 'add') {
        if (!body.merchant || !(body.amount > 0) || !/^\d{4}-\d{2}-\d{2}$/.test(body.date ?? '')) return send(res, 400, { ok: false, error: 'shape' });
        const at = kstAt(body.date, 12);
        const entry = { id: `sp${Date.now()}`, at: iso(at), date: body.date, merchant: body.merchant, amount: body.amount, category: body.category ?? 'other', categoryLabel: catLabel(body.category ?? 'other'), categorySource: 'owner', source: 'manual', hasReceipt: false };
        spendEntries.push(entry);
        return send(res, 200, { ok: true, view: name, action, data: { added: true, entryId: entry.id } });
      }
      return send(res, 404, { ok: false, error: 'no_view' });
    }
  }
  return send(res, 404, { ok: false });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', 'http://mock.local');
  const p = url.pathname;
  try {
    if (req.method === 'POST' && p === `/m/p/${NONCE}/app`) {
      const body = await readJson(req);
      if (body?.code !== CODE) return send(res, 403, { ok: false, error: 'wrong', attemptsLeft: 4 });
      const token = `mock-${randomBytes(24).toString('hex')}`;
      tokens.add(token);
      return send(res, 200, { ok: true, deviceId: `d_${randomBytes(4).toString('hex')}`, deviceName: '아이폰', baseUrl: `http://${HOST}:${PORT}`, token });
    }
    if (p.startsWith('/m/p/')) return send(res, 410, { ok: false, error: 'expired' });
    if (p.startsWith('/m/v1/app/')) return await app(req, res, p.slice('/m/v1/app/'.length), url);
    // Dev helpers (no auth, this machine only): make things happen while watching the app.
    if (p === '/dev/teamplan') {
      teamPlan = freshTeamPlan();
      teamPlanCard();
      return send(res, 200, { ok: true });
    }
    if (p === '/dev/card') {
      openCard({ cardId: `pay-${Date.now()}`, summary: '노트북 거치대를 쿠팡에서 살까요?', effects: ['pay'], amount: { value: 51250, currency: 'KRW' }, merchant: '쿠팡', note: '내일 도착' });
      return send(res, 200, { ok: true });
    }
    if (p === '/dev/browser') {
      const reason = url.searchParams.get('reason') ?? 'login';
      liveOpenPending(reason);
      // §22: new servers put `live` on the reply (the wording may differ); `?old=1` = an older server, sentence only.
      if (url.searchParams.get('old')) append({ type: 'message', role: 'assistant', text: "쇼핑몰 로그인이 필요해서 멈췄어요. 앱의 브라우저 화면에서 직접 하실 수 있어요. 다 하셨으면 그 화면에서 '다 했어요'를 눌러 주세요." });
      else append({ type: 'message', role: 'assistant', text: '쇼핑몰 로그인 단계에서 멈췄어요. 로그인만 해 주시면 이어서 할게요.', live: { view: 'browser-live', reason, url: 'https://shop.example.com/login' } });
      return send(res, 200, { ok: true });
    }
    if (p === '/dev/think') {
      // Activity only (no answer): ?channel=dev&ms=20000 — watch the dots, then idle.
      const ch = url.searchParams.get('channel') ?? '';
      activity(ch, 'thinking');
      later(3000, () => activity(ch, 'working', url.searchParams.get('step') ?? '메일 보는 중'));
      later(Number(url.searchParams.get('ms') ?? 20000), () => activity(ch, 'idle'));
      return send(res, 200, { ok: true });
    }
    if (p === '/dev/notice') {
      const kind = url.searchParams.get('kind') ?? undefined;
      append({ type: 'notice', text: url.searchParams.get('text') ?? '알림 시험이에요.', ...(kind ? { kind } : {}),
        ...(kind === 'browser.task' ? { live: { view: 'browser-live', reason: '로그인을 직접 해 주세요', url: 'https://example.com/login' } } : {}) });
      return send(res, 200, { ok: true });
    }
    return send(res, 404, { ok: false });
  } catch (error) {
    console.error(error);
    return send(res, 500, { ok: false });
  }
});

server.listen(PORT, HOST, () => {
  const link = `axkit://pair?u=${encodeURIComponent(`http://${HOST}:${PORT}`)}&n=${NONCE}&c=${CODE}`;
  console.log(`가짜 맥이 켜졌어요: http://${HOST}:${PORT}`);
  console.log(`연결 링크: ${link}`);
  console.log(`시뮬레이터: xcrun simctl openurl booted '${link}'`);
  console.log(`새 결제 카드: curl -s http://${HOST}:${PORT}/dev/card`);
});
