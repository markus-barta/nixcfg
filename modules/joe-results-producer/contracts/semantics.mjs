import { decimalUnits } from './decimal.mjs';
import { gatewayReason } from './gateway.mjs';
import { viennaDay } from './vienna-date.mjs';
import resultsSchema from './results.schema.json' with { type: 'json' };

const PARTIAL_REASONS = resultsSchema.properties.days.items.properties.partialReasons.items.enum;

const FIELDS = ['equity', 'dayPnl', 'openPnl', 'totalPnl'];
const KEEP = ['SXR8', 'TSLA'];
const DESKS = ['j', 'joe', 'joel'];

export function checkSemantics(kind, payload, stage, errors, receivedAt) {
  const fail = (path, rule) => { if (errors.length < 32) errors.push({ path, rule }); };
  const eur = (money, path) => {
    if (money && money.currency !== 'EUR') fail(path, 'EUR');
  };
  function walk(value, path) {
    if (!value || typeof value !== 'object') return;
    if (Object.hasOwn(value, 'amount') && Object.hasOwn(value, 'currency') && value.fx) {
      if (value.fx.quote !== value.currency) fail(path, 'fxCurrency');
    }
    if (Object.hasOwn(value, 'rate') && Object.hasOwn(value, 'base') && decimalUnits(value.rate) <= 0n) fail(path, 'positiveFxRate');
    Object.entries(value).forEach(([k, v]) => walk(v, `${path}.${k}`));
  }
  walk(payload, '$');
  if (['data', 'history', 'results'].includes(kind)) {
    if (stage === 'served' && !payload.receivedAt) fail('$.receivedAt', 'required');
    if (stage === 'ingress' && Object.hasOwn(payload, 'receivedAt')) fail('$.receivedAt', 'serverOwned');
  }
  const checkBag = (bag, path) => FIELDS.forEach(f => eur(bag?.[f], `${path}.${f}`));
  const checkDeskSum = (desks, totals, path) => {
    for (const field of FIELDS) {
      const parts = desks.map(d => d?.money[field]);
      const total = totals[field];
      if (parts.every(Boolean) && total && parts.reduce((sum, v) => sum + decimalUnits(v.amount), 0n) !== decimalUnits(total.amount)) {
        fail(`${path}.${field}`, 'deskSum');
      }
      if (parts.some(v => !v) && total) fail(`${path}.${field}`, 'incompleteDeskSum');
    }
  };
  if (kind === 'data') {
    if (new Set(payload.desks.map(d => d.id)).size !== 3) fail('$.desks', 'uniqueDesk');
    checkBag(payload.totals, '$.totals');
    payload.desks.forEach((d, i) => {
      checkBag(d.money, `$.desks[${i}].money`);
      if (d.backfill && d.id !== 'j') fail(`$.desks[${i}].backfill`, 'jOnly');
      if (d.backfill?.fullTotalAvailable && (d.backfill.status !== 'COMPLETE' ||
          d.backfill.coverage.gapCount || d.backfill.missingOpeningLotCount || d.backfill.orphanCommissionCount)) {
        fail(`$.desks[${i}].backfill`, 'incompleteCoverage');
      }
    });
    eur(payload.brokerAccount?.equity, '$.brokerAccount.equity');
    checkDeskSum(payload.desks, payload.totals, '$.totals');
    for (const [kind, field] of [['day', 'dayPnl'], ['open', 'openPnl']]) {
      const source = payload.pnlSources?.[kind];
      const values = [payload.totals[field], ...payload.desks.map(d => d.money[field])];
      if (values.some(Boolean) && (source?.status !== 'available' || !source.method || !source.observedAt)) fail(`$.pnlSources.${kind}`, 'evidenceRequired');
      if (source?.status === 'available' && !values.every(Boolean)) fail(`$.pnlSources.${kind}`, 'completeEvidenceRequired');
      if (source?.status === 'available' && kind === 'day' && !['ib-daily-pnl', 'sod-virtual-equity', 'session-open-estimate'].includes(source.method)) fail('$.pnlSources.day', 'dayMethod');
      if (kind === 'day' && /^session_open_proxy(?:\b|[: _-])/.test(source?.detail ?? '') && source.method !== 'session-open-estimate') fail('$.pnlSources.day.method', 'estimateMethodRequired');
      if (source?.status === 'available' && kind === 'open' && !['ib-unrealized-pnl', 'owned-lots-current-mark-fx'].includes(source.method)) fail('$.pnlSources.open', 'openMethod');
      if (['sod-virtual-equity', 'session-open-estimate'].includes(source?.method) && !source.periodStart) fail(`$.pnlSources.${kind}.periodStart`, 'baselineRequired');
    }
    payload.positions?.rows.forEach((p, i) => {
      if ((KEEP.includes(p.symbol) && p.scope !== 'keep') || (p.scope === 'keep' && p.desk !== null)) fail(`$.positions.rows[${i}]`, 'keepExcluded');
      if (p.scope === 'stage0' && !DESKS.includes(p.desk)) fail(`$.positions.rows[${i}]`, 'deskRequired');
      for (const field of ['mark', 'marketValue', 'dayPnl', 'openPnl']) {
        if (p[field] && p.mark && p[field].currency !== p.mark.currency) fail(`$.positions.rows[${i}].${field}`, 'nativeCurrency');
      }
    });
    const gateway = payload.safety.gateway;
    if (gateway && !gateway.apiSessionReady && !gateway.reason) fail('$.safety.gateway.reason', 'reasonRequired');
    if (gateway?.apiSessionReady && gateway.reason) fail('$.safety.gateway', 'contradictorySession');
    // An advancing envelope cannot confirm an absent or relayed old check.
    // Validate producer-relative age here; selectors add server elapsed time
    // since the last advancing generation without mixing the two clocks.
    if (gatewayReason(gateway, payload.generatedAt)) {
      payload.desks.forEach((desk, i) => {
        if (desk.moneyEvidence) fail(`$.desks[${i}].moneyEvidence`, 'sessionUnavailable');
      });
      const unavailable = (value, path, reason) => {
        if (value != null) fail(path, 'sessionUnavailable');
        if (!reason) fail(path, 'reasonRequired');
      };
      for (const [bag, path] of [[payload.totals, '$.totals'],
        ...payload.desks.map((d, i) => [d.money, `$.desks[${i}].money`])]) {
        for (const field of FIELDS) if (Object.hasOwn(bag, field)) {
          unavailable(bag[field], `${path}.${field}`, bag.reasons?.[field]);
        }
      }
      if (payload.brokerAccount) unavailable(payload.brokerAccount.equity, '$.brokerAccount.equity', payload.brokerAccount.reason);
      if (payload.positions) {
        if (!payload.positions.reason) fail('$.positions.reason', 'reasonRequired');
        payload.positions.rows.forEach((row, i) => {
          for (const field of ['mark', 'marketValue', 'dayPnl', 'openPnl']) {
            if (row[field] != null) fail(`$.positions.rows[${i}].${field}`, 'sessionUnavailable');
          }
        });
      }
    }
    if (payload.safety.halt && !payload.safety.haltReason) fail('$.safety.haltReason', 'reasonRequired');
  }
  if (kind === 'history') {
    if (payload.reason === 'history_compacted' && !payload.compactedThrough) fail('$.compactedThrough', 'required');
    let previous = -Infinity;
    payload.points.forEach((p, i) => {
      if (Date.parse(p.t) <= previous) fail(`$.points[${i}].t`, 'strictOrder');
      previous = Date.parse(p.t);
      checkBag(p.totals, `$.points[${i}].totals`);
      Object.entries(p.desks).forEach(([id, d]) => checkBag(d.money, `$.points[${i}].desks.${id}.money`));
      checkDeskSum(DESKS.map(id => p.desks[id]), p.totals, `$.points[${i}].totals`);
    });
  }
  if (kind === 'results') {
    if (stage === 'ingress' && Object.hasOwn(payload, 'missingDays')) fail('$.missingDays', 'serverOwned');
    // Ingress gets the trusted server receipt from acceptSnapshot; served
    // validation uses the persisted receipt, never a reader's current clock.
    const receipt = stage === 'ingress' ? receivedAt : payload.receivedAt;
    const today = receipt ? viennaDay(receipt) : null;
    const seen = new Set();
    const closed = new Map();
    payload.trades.forEach((t, i) => {
      const at = `$.trades[${i}]`;
      if (seen.has(t.id)) fail(`${at}.id`, 'uniqueTrade');
      seen.add(t.id);
      if (KEEP.includes(t.symbol)) fail(`${at}.symbol`, 'keepExcluded');
      if (Date.parse(t.openedAt) > Date.parse(t.closedAt)) fail(at, 'tradeTimeOrder');
      if (decimalUnits(t.quantity) <= 0n) fail(`${at}.quantity`, 'positive');
      ['grossEur', 'feesEur', 'netEur'].forEach(f => eur(t[f], `${at}.${f}`));
      if (t.entryPrice.currency !== t.exitPrice.currency || t.fx.base !== t.entryPrice.currency) fail(at, 'fxCurrency');
      if (decimalUnits(t.feesEur.amount) < 0n) fail(`${at}.feesEur`, 'nonnegative');
      if (decimalUnits(t.grossEur.amount) - decimalUnits(t.feesEur.amount) !== decimalUnits(t.netEur.amount)) fail(at, 'netAfterFees');
      const key = `${viennaDay(t.closedAt)}|${t.desk}`;
      const sum = closed.get(key) ?? { trades: 0, realisedNet: 0n, fees: 0n };
      sum.trades++;
      sum.realisedNet += decimalUnits(t.netEur.amount);
      sum.fees += decimalUnits(t.feesEur.amount);
      closed.set(key, sum);
    });
    // Partial days have incomplete numbers. Full days cover every
    // desk that closed trades, including desks missing from the summary.
    // Dates absent from days[] are not yet reconciled. Never round the sums.
    payload.days.forEach((day, i) => {
      const at = `$.days[${i}]`;
      if (today && day.date < today && day.coverage === 'partial' && !day.partialReasons?.length)
        fail(`${at}.partialReasons`, 'partialReasonsRequired');
      if (day.partialReasons) {
        if (day.coverage !== 'partial') fail(`${at}.partialReasons`, 'partialCoverageRequired');
        if (day.partialReasons.some((reason, j, reasons) => j && PARTIAL_REASONS.indexOf(reason) <= PARTIAL_REASONS.indexOf(reasons[j - 1])))
          fail(`${at}.partialReasons`, 'canonicalOrder');
      }
      if (Object.hasOwn(day, 'unattributedCount') && !day.partialReasons?.includes('unattributed_activity'))
        fail(`${at}.unattributedCount`, 'unattributedReasonRequired');
      Object.entries(day.desks).forEach(([id, d]) => {
        ['equityClose', 'realisedNet', 'fees'].forEach(f => eur(d[f], `$.days[${i}].desks.${id}.${f}`));
      });
      if (day.coverage === 'partial') return;
      for (const id of DESKS) {
        const at = `$.days[${i}].desks.${id}`;
        const d = day.desks[id];
        const sum = closed.get(`${day.date}|${id}`) ?? { trades: 0, realisedNet: 0n, fees: 0n };
        if (!d) {
          if (sum.trades) fail(at, 'dayDeskRequired');
          continue;
        }
        if (d.trades !== sum.trades) fail(`${at}.trades`, 'dayTradeCount');
        if (!d.realisedNet || decimalUnits(d.realisedNet.amount) !== sum.realisedNet) fail(`${at}.realisedNet`, 'dayNetSum');
        if (!d.fees || decimalUnits(d.fees.amount) !== sum.fees) fail(`${at}.fees`, 'dayFeeSum');
      }
    });
  }
  if (kind === 'healthz') {
    // Strict schema is the allowlist; no free text, money or identifiers.
    for (const [key, feed] of Object.entries(payload.feeds)) {
      if (['stale', 'broken'].includes(feed.state) && !feed.reason) fail(`$.feeds.${key}.reason`, 'reasonRequired');
      if (feed.state === 'fresh' && feed.reason) fail(`$.feeds.${key}`, 'freshWithReason');
      if (feed.state !== 'not reported' && feed.ageSeconds === null && feed.state !== 'broken') fail(`$.feeds.${key}.ageSeconds`, 'ageRequired');
    }
    const coordinate = payload.versionScheme === 'calendar' ? payload.version.replaceAll('.', '').padEnd(12, '0') : payload.version.slice(0, 12);
    const schemeShape = payload.versionScheme === 'calendar' ? /^\d{2}\.\d{2}\.\d{2}(?:\.\d{2}\.\d{2})?$/ : /^[1-9]\d{11}\.0\.0$/;
    if (!schemeShape.test(payload.version)) fail('$.version', 'versionScheme');
    const instant = `20${coordinate.slice(0, 2)}-${coordinate.slice(2, 4)}-${coordinate.slice(4, 6)}T${coordinate.slice(6, 8)}:${coordinate.slice(8, 10)}:${coordinate.slice(10, 12)}.000Z`;
    if (!Number.isFinite(Date.parse(instant)) || new Date(instant).toISOString() !== instant) fail('$.version', 'calendarCoordinate');
    if (payload.gateway?.confirmed && (payload.gateway.reason || payload.gateway.checkAgeSeconds === null || payload.gateway.checkAgeSeconds >= 60)) fail('$.gateway', 'contradictorySession');
    if (payload.gateway && !payload.gateway.confirmed && !payload.gateway.reason) fail('$.gateway.reason', 'reasonRequired');
  }
}
