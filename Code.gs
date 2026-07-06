/**
 * 보드게임 동아리 관리 웹앱 — Google Apps Script 백엔드
 * GET-only JSON API (doGet action 라우팅)
 *
 * 시트 4장: Players / Games / Ratings / PlayLogs
 * 응답 포맷: { ok: true, data: ... }  또는  { ok: false, error: "메시지" }
 *
 * 배포: 웹앱으로 배포 (실행: 나, 액세스: 모든 사용자)
 */

// ===== 설정 =====
var SHEET_ID = ''; // 비워두면 컨테이너 바운드 스프레드시트(getActiveSpreadsheet) 사용

var SHEETS = {
  PLAYERS: 'Players',
  GAMES: 'Games',
  RATINGS: 'Ratings',
  PLAYLOGS: 'PlayLogs'
};

// 카테고리(분류) 탭 이름 후보 — 이 중 먼저 존재하는 시트에서 읽음
var CATEGORY_SHEET_NAMES = ['Categories', '분류', '카테고리'];
// 탭이 없을 때 사용할 기본 분류
var DEFAULT_CATEGORIES = ['전략', '마피아', '트릭테이킹', '파티', '협력', '덱빌딩', '추리', '가족', '아브스트랙트', '기타'];

// ===== 진입점 =====
function doGet(e) {
  var params = (e && e.parameter) ? e.parameter : {};
  var action = params.action || '';
  try {
    var data;
    switch (action) {
      case 'login':          data = actionLogin(params); break;
      case 'signup':         data = actionSignup(params); break;
      case 'getGames':       data = actionGetGames(params); break;
      case 'getPlays':       data = actionGetPlays(params); break;
      case 'getPlayerStats': data = actionGetPlayerStats(params); break;
      case 'getMyRatings':   data = actionGetMyRatings(params); break;
      case 'getPlayers':     data = actionGetPlayers(params); break;
      case 'getCategories':  data = actionGetCategories(params); break;
      case 'addGame':        data = actionAddGame(params); break;
      case 'saveRating':     data = actionSaveRating(params); break;
      case 'addPlay':        data = actionAddPlay(params); break;
      case 'updatePlay':     data = actionUpdatePlay(params); break;
      case 'deletePlay':     data = actionDeletePlay(params); break;
      case 'updateGame':     data = actionUpdateGame(params); break;
      default:
        return jsonOutput({ ok: false, error: 'Unknown action: ' + action });
    }
    return jsonOutput({ ok: true, data: data });
  } catch (err) {
    return jsonOutput({ ok: false, error: (err && err.message) ? err.message : String(err) });
  }
}

// GET-only 아키텍처지만, 혹시 모를 POST 요청도 동일하게 처리
function doPost(e) {
  return doGet(e);
}

// ===== 공통 유틸 =====
function jsonOutput(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

function getSpreadsheet() {
  if (SHEET_ID) return SpreadsheetApp.openById(SHEET_ID);
  return SpreadsheetApp.getActiveSpreadsheet();
}

function getSheet(name) {
  var ss = getSpreadsheet();
  var sh = ss.getSheetByName(name);
  if (!sh) throw new Error('시트를 찾을 수 없습니다: ' + name);
  return sh;
}

/**
 * 헤더명 기반으로 시트를 객체 배열로 읽음.
 * 날짜 자동변환 방지를 위해 getDisplayValues() 사용.
 * 반환: { headers: [...], rows: [{header: value, _rowIndex: n}], sheet }
 */
function readSheet(name) {
  var sh = getSheet(name);
  var range = sh.getDataRange();
  var values = range.getDisplayValues();
  if (values.length === 0) return { headers: [], rows: [], sheet: sh };
  var headers = values[0].map(function (h) { return String(h).trim(); });
  var rows = [];
  for (var i = 1; i < values.length; i++) {
    var obj = {};
    for (var c = 0; c < headers.length; c++) {
      if (!headers[c]) continue;
      obj[headers[c]] = values[i][c];
    }
    obj._rowIndex = i + 1; // 시트상의 실제 행 번호(1-based)
    rows.push(obj);
  }
  return { headers: headers, rows: rows, sheet: sh };
}

function headerIndexMap(sheet) {
  var lastCol = sheet.getLastColumn();
  if (lastCol === 0) return {};
  var headers = sheet.getRange(1, 1, 1, lastCol).getDisplayValues()[0];
  var map = {};
  for (var i = 0; i < headers.length; i++) {
    var h = String(headers[i]).trim();
    if (h) map[h] = i; // 0-based
  }
  return map;
}

/**
 * 객체를 헤더 순서에 맞춰 시트 마지막에 추가.
 */
function appendRowByHeader(sheetName, obj) {
  var sh = getSheet(sheetName);
  var map = headerIndexMap(sh);
  var lastCol = sh.getLastColumn();
  var row = new Array(lastCol).fill('');
  Object.keys(obj).forEach(function (k) {
    if (map.hasOwnProperty(k)) row[map[k]] = obj[k];
  });
  sh.appendRow(row);
  return sh.getLastRow();
}

function sha256Hex(text) {
  var bytes = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, String(text), Utilities.Charset.UTF_8);
  return bytes.map(function (b) {
    var v = (b < 0 ? b + 256 : b).toString(16);
    return v.length === 1 ? '0' + v : v;
  }).join('');
}

function nowIso() {
  return Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd HH:mm:ss');
}

function todayStr() {
  return Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd');
}

function toNum(v) {
  if (v === '' || v === null || v === undefined) return null;
  var n = Number(String(v).replace(/,/g, ''));
  return isNaN(n) ? null : n;
}

function round1(n) {
  return Math.round(n * 10) / 10;
}

/**
 * 새 ID 생성: prefix + zero-padded 최대번호+1
 */
function nextId(rows, field, prefix, pad) {
  var max = 0;
  rows.forEach(function (r) {
    var v = String(r[field] || '');
    var m = v.match(new RegExp('^' + prefix + '(\\d+)$'));
    if (m) { var n = parseInt(m[1], 10); if (n > max) max = n; }
  });
  var next = max + 1;
  var s = String(next);
  while (s.length < pad) s = '0' + s;
  return prefix + s;
}

// ===== 인증 =====
function findPlayerById(playerId) {
  var players = readSheet(SHEETS.PLAYERS).rows;
  for (var i = 0; i < players.length; i++) {
    if (String(players[i].player_id) === String(playerId)) return players[i];
  }
  return null;
}

function findPlayerByName(name) {
  var players = readSheet(SHEETS.PLAYERS).rows;
  for (var i = 0; i < players.length; i++) {
    if (String(players[i].name) === String(name)) return players[i];
  }
  return null;
}

// PIN 대조: 시트의 평문 'pin' 컬럼을 기준으로 함(관리자가 pin 셀을 고치면 비밀번호가 바뀜).
// 평문 pin이 비어 있는 레거시 행만 예외적으로 pin_hash로 대조.
function checkPin(playerRow, pin) {
  var plain = String(playerRow.pin == null ? '' : playerRow.pin).trim();
  if (plain !== '') return plain === String(pin).trim();
  return String(playerRow.pin_hash) === sha256Hex(pin);
}

function verifyByPlayerId(playerId, pin) {
  var p = findPlayerById(playerId);
  if (!p) throw new Error('사용자를 찾을 수 없습니다.');
  if (!checkPin(p, pin)) throw new Error('PIN이 올바르지 않습니다.');
  return p;
}

// ===== Actions =====

function actionLogin(params) {
  var name = params.name;
  var pin = params.pin;
  if (!name || !pin) throw new Error('이름과 PIN을 입력하세요.');
  var p = findPlayerByName(name);
  if (!p) throw new Error('사용자를 찾을 수 없습니다.');
  if (!checkPin(p, pin)) throw new Error('PIN이 올바르지 않습니다.');
  return { player_id: p.player_id, name: p.name, role: p.role || 'member' };
}

function actionSignup(params) {
  var name = (params.name || '').trim();
  var pin = (params.pin || '').trim();
  if (!name) throw new Error('닉네임을 입력하세요.');
  if (name.length > 20) throw new Error('닉네임은 20자 이하로 입력하세요.');
  if (!/^\d{4}$/.test(pin)) throw new Error('비밀번호는 숫자 4자리로 입력하세요.');

  var read = readSheet(SHEETS.PLAYERS);
  var dup = read.rows.some(function (r) { return String(r.name).trim() === name; });
  if (dup) throw new Error('이미 사용 중인 닉네임입니다.');

  var playerId = nextId(read.rows, 'player_id', 'P', 3);
  // 첫 가입자는 관리자(게임 정보 수정 권한), 이후는 일반 회원
  var role = read.rows.length === 0 ? 'admin' : 'member';

  appendRowByHeader(SHEETS.PLAYERS, {
    player_id: playerId,
    name: name,
    pin: pin,               // 비밀번호는 pin 컬럼(평문)에 그대로 저장. 관리자가 이 값을 고치면 비밀번호가 바뀜
    role: role,
    joined_at: todayStr()
  });
  return { player_id: playerId, name: name, role: role };
}

function actionGetCategories(params) {
  var ss = getSpreadsheet();
  var sh = null;
  for (var i = 0; i < CATEGORY_SHEET_NAMES.length; i++) {
    sh = ss.getSheetByName(CATEGORY_SHEET_NAMES[i]);
    if (sh) break;
  }
  if (!sh) return DEFAULT_CATEGORIES;

  var last = sh.getLastRow();
  if (last < 1) return DEFAULT_CATEGORIES;

  // 첫 번째 열의 값들을 읽음. 1행이 헤더(category/분류/카테고리)면 건너뜀.
  var vals = sh.getRange(1, 1, last, 1).getDisplayValues();
  var out = [];
  for (var r = 0; r < vals.length; r++) {
    var v = String(vals[r][0]).trim();
    if (!v) continue;
    if (r === 0) {
      var low = v.toLowerCase();
      if (low === 'category' || v === '분류' || v === '카테고리' || low === 'categories') continue;
    }
    if (out.indexOf(v) === -1) out.push(v);
  }
  return out.length ? out : DEFAULT_CATEGORIES;
}

function actionGetPlayers(params) {
  var players = readSheet(SHEETS.PLAYERS).rows;
  return players.map(function (p) {
    return { player_id: p.player_id, name: p.name, role: p.role || 'member' };
  });
}

function actionGetGames(params) {
  var games = readSheet(SHEETS.GAMES).rows;
  var ratings = readSheet(SHEETS.RATINGS).rows;
  var plays = readSheet(SHEETS.PLAYLOGS).rows;

  // 게임별 rating 집계
  var ratingAgg = {}; // game_id -> {sum, count}
  ratings.forEach(function (r) {
    var gid = r.game_id;
    var val = toNum(r.rating);
    if (val === null) return;
    if (!ratingAgg[gid]) ratingAgg[gid] = { sum: 0, count: 0 };
    ratingAgg[gid].sum += val;
    ratingAgg[gid].count += 1;
  });

  // 게임별 플레이 세션 수 (session_id distinct)
  var playAgg = {}; // game_id -> Set(session_id)
  plays.forEach(function (p) {
    var gid = p.game_id;
    if (!playAgg[gid]) playAgg[gid] = {};
    playAgg[gid][p.session_id] = true;
  });

  return games.map(function (g) {
    var agg = ratingAgg[g.game_id];
    var clubRating = (agg && agg.count > 0) ? round1(agg.sum / agg.count) : null;
    var playCount = playAgg[g.game_id] ? Object.keys(playAgg[g.game_id]).length : 0;
    return {
      game_id: g.game_id,
      name_kr: g.name_kr,
      name_en: g.name_en,
      bgg_id: g.bgg_id,
      category: g.category,
      min_players: toNum(g.min_players),
      max_players: toNum(g.max_players),
      playtime_min: toNum(g.playtime_min),
      weight: toNum(g.weight),
      bgg_rating: toNum(g.bgg_rating),
      summary_kr: g.summary_kr,
      image_url: g.image_url,
      source: g.source,
      club_rating: clubRating,
      rating_count: agg ? agg.count : 0,
      play_count: playCount
    };
  });
}

function actionGetPlays(params) {
  var plays = readSheet(SHEETS.PLAYLOGS).rows;
  var games = readSheet(SHEETS.GAMES).rows;
  var players = readSheet(SHEETS.PLAYERS).rows;

  var gameMap = {};
  games.forEach(function (g) { gameMap[g.game_id] = g; });
  var playerMap = {};
  players.forEach(function (p) { playerMap[p.player_id] = p; });

  // session_id로 그룹핑
  var sessions = {}; // session_id -> {...}
  var order = [];
  plays.forEach(function (p) {
    var sid = p.session_id;
    if (!sessions[sid]) {
      var g = gameMap[p.game_id] || {};
      sessions[sid] = {
        session_id: sid,
        play_date: p.play_date,
        game_id: p.game_id,
        game_name: g.name_kr || g.name_en || '(알 수 없는 게임)',
        game_image: g.image_url || '',
        duration_min: toNum(p.duration_min),
        created_by: p.created_by || '',   // 입력자(본인 수정/삭제 판별용)
        participants: []
      };
      order.push(sid);
    }
    var pl = playerMap[p.player_id] || {};
    var isGuest = !p.player_id || !playerMap[p.player_id];
    sessions[sid].participants.push({
      record_id: p.record_id,
      player_id: p.player_id,
      // 이름은 player_name(비회원 포함) 우선, 없으면 회원명, 그래도 없으면 player_id
      name: (p.player_name && String(p.player_name).trim()) || pl.name || p.player_id,
      is_guest: isGuest,
      score: (p.score === '' || p.score === undefined) ? null : toNum(p.score),
      is_win: String(p.is_win).toUpperCase() === 'TRUE'
    });
  });

  var result = order.map(function (sid) { return sessions[sid]; });
  // 최신순 정렬: play_date 내림차순, 동일 날짜는 session_id 내림차순
  result.sort(function (a, b) {
    if (a.play_date !== b.play_date) return a.play_date < b.play_date ? 1 : -1;
    return a.session_id < b.session_id ? 1 : -1;
  });
  return result;
}

function actionGetPlayerStats(params) {
  var playerId = params.playerId;
  if (!playerId) throw new Error('playerId가 필요합니다.');
  var plays = readSheet(SHEETS.PLAYLOGS).rows;
  var games = readSheet(SHEETS.GAMES).rows;
  var gameMap = {};
  games.forEach(function (g) { gameMap[g.game_id] = g; });

  var mine = plays.filter(function (p) { return String(p.player_id) === String(playerId); });

  var totalPlays = mine.length;
  var totalWins = 0;
  var perGame = {}; // game_id -> {plays, wins}
  var monthly = {}; // 'YYYY-MM' -> count

  mine.forEach(function (p) {
    var win = String(p.is_win).toUpperCase() === 'TRUE';
    if (win) totalWins++;
    var gid = p.game_id;
    if (!perGame[gid]) perGame[gid] = { plays: 0, wins: 0 };
    perGame[gid].plays++;
    if (win) perGame[gid].wins++;
    var ym = String(p.play_date).substring(0, 7);
    if (ym) monthly[ym] = (monthly[ym] || 0) + 1;
  });

  var winRate = totalPlays > 0 ? round1(totalWins / totalPlays * 100) : 0;

  var thisMonth = todayStr().substring(0, 7);
  var thisMonthPlays = monthly[thisMonth] || 0;

  var byGame = Object.keys(perGame).map(function (gid) {
    var g = gameMap[gid] || {};
    var pg = perGame[gid];
    return {
      game_id: gid,
      game: g.name_kr || g.name_en || gid,
      image_url: g.image_url || '',
      plays: pg.plays,
      wins: pg.wins,
      win_rate: pg.plays > 0 ? round1(pg.wins / pg.plays * 100) : 0
    };
  });
  byGame.sort(function (a, b) {
    if (b.win_rate !== a.win_rate) return b.win_rate - a.win_rate;
    return b.plays - a.plays;
  });

  // 월별 미니차트용 (최근 6개월)
  var monthlyArr = [];
  var d = new Date();
  for (var i = 5; i >= 0; i--) {
    var dt = new Date(d.getFullYear(), d.getMonth() - i, 1);
    var key = Utilities.formatDate(dt, Session.getScriptTimeZone(), 'yyyy-MM');
    monthlyArr.push({ month: key, count: monthly[key] || 0 });
  }

  return {
    total_plays: totalPlays,
    total_wins: totalWins,
    win_rate: winRate,
    this_month_plays: thisMonthPlays,
    monthly: monthlyArr,
    by_game: byGame
  };
}

function actionGetMyRatings(params) {
  var playerId = params.playerId;
  if (!playerId) throw new Error('playerId가 필요합니다.');
  var ratings = readSheet(SHEETS.RATINGS).rows;
  var games = readSheet(SHEETS.GAMES).rows;
  var gameMap = {};
  games.forEach(function (g) { gameMap[g.game_id] = g; });

  return ratings
    .filter(function (r) { return String(r.player_id) === String(playerId); })
    .map(function (r) {
      var g = gameMap[r.game_id] || {};
      return {
        game_id: r.game_id,
        game: g.name_kr || g.name_en || r.game_id,
        rating: toNum(r.rating),
        memo: r.memo || '',
        updated_at: r.updated_at
      };
    });
}

function actionSaveRating(params) {
  var playerId = params.playerId;
  var pin = params.pin;
  var gameId = params.gameId;
  var rating = params.rating;
  var memo = params.memo || '';
  if (!playerId || !gameId) throw new Error('playerId와 gameId가 필요합니다.');
  verifyByPlayerId(playerId, pin);

  var ratingNum = toNum(rating);
  if (ratingNum === null || ratingNum < 1 || ratingNum > 10) {
    throw new Error('평점은 1~10 사이여야 합니다.');
  }

  var sh = getSheet(SHEETS.RATINGS);
  var read = readSheet(SHEETS.RATINGS);
  var map = headerIndexMap(sh);

  // upsert: (player_id, game_id) 조합
  var existing = null;
  for (var i = 0; i < read.rows.length; i++) {
    var r = read.rows[i];
    if (String(r.player_id) === String(playerId) && String(r.game_id) === String(gameId)) {
      existing = r; break;
    }
  }

  var updatedAt = nowIso();
  if (existing) {
    var rowIdx = existing._rowIndex;
    if (map.rating !== undefined)     sh.getRange(rowIdx, map.rating + 1).setValue(ratingNum);
    if (map.memo !== undefined)       sh.getRange(rowIdx, map.memo + 1).setValue(memo);
    if (map.updated_at !== undefined) sh.getRange(rowIdx, map.updated_at + 1).setValue(updatedAt);
  } else {
    appendRowByHeader(SHEETS.RATINGS, {
      player_id: playerId,
      game_id: gameId,
      rating: ratingNum,
      memo: memo,
      updated_at: updatedAt
    });
  }
  return { player_id: playerId, game_id: gameId, rating: ratingNum, memo: memo, updated_at: updatedAt };
}

function actionAddPlay(params) {
  var payloadStr = params.payload;
  if (!payloadStr) throw new Error('payload가 필요합니다.');
  var payload = JSON.parse(payloadStr);

  // 인증
  var authId = payload.player_id || params.playerId;
  var pin = payload.pin || params.pin;
  if (!authId || !pin) throw new Error('인증 정보가 필요합니다.');
  verifyByPlayerId(authId, pin);

  var participants = payload.participants || [];
  if (!participants.length) throw new Error('참가자가 없습니다.');
  if (!payload.game_id) throw new Error('게임을 선택하세요.');

  var read = readSheet(SHEETS.PLAYLOGS);
  var sessionId = nextId(read.rows, 'session_id', 'S', 4);

  // record_id는 R + 5자리, 기존 최대값 기준
  var maxRec = 0;
  read.rows.forEach(function (r) {
    var m = String(r.record_id || '').match(/^R(\d+)$/);
    if (m) { var n = parseInt(m[1], 10); if (n > maxRec) maxRec = n; }
  });

  var playDate = payload.play_date || todayStr();
  var duration = (payload.duration_min === '' || payload.duration_min === undefined || payload.duration_min === null)
    ? '' : toNum(payload.duration_min);
  var createdAt = nowIso();

  participants.forEach(function (pt) {
    maxRec++;
    var rid = 'R' + String(maxRec).padStart(5, '0');
    appendRowByHeader(SHEETS.PLAYLOGS, {
      record_id: rid,
      session_id: sessionId,
      play_date: playDate,
      game_id: payload.game_id,
      duration_min: duration,
      player_id: pt.player_id || '',                 // 게스트는 빈값
      player_name: pt.player_name || '',             // 회원/게스트 모두 표시 이름 저장
      score: (pt.score === '' || pt.score === undefined || pt.score === null) ? '' : pt.score,
      is_win: pt.is_win ? 'TRUE' : 'FALSE',
      created_by: authId,                            // 입력자(본인만 수정/삭제 가능)
      created_at: createdAt
    });
  });

  return { session_id: sessionId, count: participants.length };
}

// 플레이 세션 수정(날짜·시간·점수·승패). 입력자 본인만 가능.
function actionUpdatePlay(params) {
  var payload = JSON.parse(params.payload || '{}');
  var authId = params.playerId || payload.player_id;
  var pin = params.pin || payload.pin;
  if (!authId || !pin) throw new Error('인증 정보가 필요합니다.');
  verifyByPlayerId(authId, pin);

  var sid = payload.session_id;
  if (!sid) throw new Error('session_id가 필요합니다.');

  var sh = getSheet(SHEETS.PLAYLOGS);
  var read = readSheet(SHEETS.PLAYLOGS);
  var map = headerIndexMap(sh);
  var rows = read.rows.filter(function (r) { return String(r.session_id) === String(sid); });
  if (!rows.length) throw new Error('기록을 찾을 수 없습니다.');
  if (String(rows[0].created_by) !== String(authId)) throw new Error('본인이 입력한 기록만 수정할 수 있습니다.');

  var playDate = payload.play_date;
  var duration = (payload.duration_min === '' || payload.duration_min === undefined || payload.duration_min === null)
    ? '' : toNum(payload.duration_min);
  var editMap = {};
  (payload.rows || []).forEach(function (e) { editMap[e.record_id] = e; });

  rows.forEach(function (r) {
    var rowIdx = r._rowIndex;
    if (playDate && map.play_date !== undefined) sh.getRange(rowIdx, map.play_date + 1).setValue(playDate);
    if (map.duration_min !== undefined) sh.getRange(rowIdx, map.duration_min + 1).setValue(duration);
    var e = editMap[r.record_id];
    if (e) {
      if (map.score !== undefined) sh.getRange(rowIdx, map.score + 1).setValue((e.score === '' || e.score === null || e.score === undefined) ? '' : e.score);
      if (map.is_win !== undefined) sh.getRange(rowIdx, map.is_win + 1).setValue(e.is_win ? 'TRUE' : 'FALSE');
    }
  });
  return { session_id: sid, updated: rows.length };
}

// 플레이 세션 삭제(그 세션의 모든 참가자 행 삭제). 입력자 본인만 가능.
function actionDeletePlay(params) {
  var authId = params.playerId;
  var pin = params.pin;
  var sid = params.sessionId;
  if (!sid && params.payload) { try { sid = JSON.parse(params.payload).session_id; } catch (e) {} }
  if (!authId || !pin) throw new Error('인증 정보가 필요합니다.');
  verifyByPlayerId(authId, pin);
  if (!sid) throw new Error('session_id가 필요합니다.');

  var sh = getSheet(SHEETS.PLAYLOGS);
  var read = readSheet(SHEETS.PLAYLOGS);
  var rows = read.rows.filter(function (r) { return String(r.session_id) === String(sid); });
  if (!rows.length) throw new Error('기록을 찾을 수 없습니다.');
  if (String(rows[0].created_by) !== String(authId)) throw new Error('본인이 입력한 기록만 삭제할 수 있습니다.');

  // 아래 행부터 삭제(인덱스 밀림 방지)
  var idxs = rows.map(function (r) { return r._rowIndex; }).sort(function (a, b) { return b - a; });
  idxs.forEach(function (ri) { sh.deleteRow(ri); });
  return { session_id: sid, deleted: idxs.length };
}

function actionAddGame(params) {
  var payloadStr = params.payload;
  if (!payloadStr) throw new Error('payload가 필요합니다.');
  var payload = JSON.parse(payloadStr);

  // 인증 (로그인한 누구나 가능)
  var authId = payload.player_id || params.playerId;
  var pin = payload.pin || params.pin;
  if (!authId || !pin) throw new Error('인증 정보가 필요합니다.');
  var player = verifyByPlayerId(authId, pin);

  var read = readSheet(SHEETS.GAMES);
  var gameId = nextId(read.rows, 'game_id', 'G', 3);

  var record = {
    game_id: gameId,
    name_kr: payload.name_kr || '',
    name_en: payload.name_en || '',
    bgg_id: '',
    category: payload.category || '',
    min_players: '',
    max_players: '',
    playtime_min: '',
    weight: '',
    bgg_rating: '',
    summary_kr: payload.summary_kr || '',
    image_url: payload.image_url || '',
    source: 'manual',
    created_by: player.player_id,
    created_at: nowIso()
  };

  // 수동 입력값 반영
  if (payload.min_players !== undefined && payload.min_players !== '') record.min_players = toNum(payload.min_players);
  if (payload.max_players !== undefined && payload.max_players !== '') record.max_players = toNum(payload.max_players);
  if (payload.playtime_min !== undefined && payload.playtime_min !== '') record.playtime_min = toNum(payload.playtime_min);
  if (payload.weight !== undefined && payload.weight !== '') record.weight = toNum(payload.weight);

  appendRowByHeader(SHEETS.GAMES, record);
  return { game_id: gameId, name_kr: record.name_kr, source: record.source };
}

function actionUpdateGame(params) {
  var payloadStr = params.payload;
  if (!payloadStr) throw new Error('payload가 필요합니다.');
  var payload = JSON.parse(payloadStr);

  var authId = params.playerId || payload.player_id;
  var pin = params.pin || payload.pin;
  if (!authId || !pin) throw new Error('인증 정보가 필요합니다.');
  var player = verifyByPlayerId(authId, pin);
  if (String(player.role) !== 'admin') throw new Error('관리자만 수정할 수 있습니다.');

  if (!payload.game_id) throw new Error('game_id가 필요합니다.');

  var sh = getSheet(SHEETS.GAMES);
  var read = readSheet(SHEETS.GAMES);
  var map = headerIndexMap(sh);

  var target = null;
  for (var i = 0; i < read.rows.length; i++) {
    if (String(read.rows[i].game_id) === String(payload.game_id)) { target = read.rows[i]; break; }
  }
  if (!target) throw new Error('게임을 찾을 수 없습니다.');

  var editable = ['name_kr', 'name_en', 'bgg_id', 'category', 'min_players', 'max_players',
    'playtime_min', 'weight', 'bgg_rating', 'summary_kr', 'image_url'];
  editable.forEach(function (field) {
    if (payload.hasOwnProperty(field) && map[field] !== undefined) {
      sh.getRange(target._rowIndex, map[field] + 1).setValue(payload[field]);
    }
  });

  return { game_id: payload.game_id, updated: true };
}

// ===== 초기 세팅 헬퍼 (수동 실행용) =====

/**
 * 시트 4장과 헤더를 생성. 스프레드시트에서 최초 1회 수동 실행.
 */
function setupSheets() {
  var ss = getSpreadsheet();
  var defs = {
    'Players': ['player_id', 'name', 'pin_hash', 'pin', 'role', 'joined_at'],
    'Games': ['game_id', 'name_kr', 'name_en', 'bgg_id', 'category', 'min_players',
      'max_players', 'playtime_min', 'weight', 'bgg_rating', 'summary_kr',
      'image_url', 'source', 'created_by', 'created_at'],
    'Ratings': ['player_id', 'game_id', 'rating', 'memo', 'updated_at'],
    'PlayLogs': ['record_id', 'session_id', 'play_date', 'game_id', 'duration_min',
      'player_id', 'player_name', 'score', 'is_win', 'created_by', 'created_at']
  };
  Object.keys(defs).forEach(function (name) {
    var sh = ss.getSheetByName(name);
    if (!sh) sh = ss.insertSheet(name);
    sh.getRange(1, 1, 1, defs[name].length).setValues([defs[name]]);
    sh.setFrozenRows(1);
  });

  // Categories 탭: 없을 때만 생성하고 기본 분류로 채움(이미 있으면 건드리지 않음)
  if (!ss.getSheetByName('Categories') && !ss.getSheetByName('분류') && !ss.getSheetByName('카테고리')) {
    var cs = ss.insertSheet('Categories');
    cs.getRange(1, 1).setValue('category');
    cs.setFrozenRows(1);
    var rows = DEFAULT_CATEGORIES.map(function (c) { return [c]; });
    cs.getRange(2, 1, rows.length, 1).setValues(rows);
  }
}

/**
 * 플레이어 추가 헬퍼. Apps Script 편집기에서 인자 바꿔 수동 실행.
 * 예: addPlayerManual('P001', '홍길동', '1234', 'admin')
 */
function addPlayerManual(playerId, name, pin, role) {
  appendRowByHeader('Players', {
    player_id: playerId,
    name: name,
    pin_hash: sha256Hex(pin),
    pin: pin,               // 평문 PIN(관리자 확인용)
    role: role || 'member',
    joined_at: todayStr()
  });
}
