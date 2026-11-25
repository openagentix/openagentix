// The metrics summary of GET /api/v1/metrics/summary (services/console/internal/observe), and its formatting.
import type { MetricsHeadline } from './types';

export interface UserUse {
    user: string;
    costUsd: number;
    tokensIn: number;
    tokensOut: number;
    tokensCacheRead: number;
}

export interface MetricsSummary {
    window: '24h' | '7d';
    spendUsd: number;
    spendTodayUsd: number;
    tokensIn: number;
    tokensOut: number;
    requests: number;
    cacheReadShare?: number;
    byUser: UserUse[];
    series: number[];
    generatedAt: string;
}

export function usd(n: number): string {
    if (n === 0) return '$0';
    return n < 1 ? `$${n.toFixed(3)}` : `$${n.toFixed(2)}`;
}

export function compact(n: number): string {
    const a = Math.abs(n);
    if (a >= 1e9) return `${+(n / 1e9).toPrecision(3)}B`;
    if (a >= 1e6) return `${+(n / 1e6).toPrecision(3)}M`;
    if (a >= 1e3) return `${+(n / 1e3).toPrecision(3)}K`;
    return String(Math.round(n));
}

/** The three headline tiles of the Overview: spend today, tokens today (here: in the window) and model requests. */
export function headline(m: MetricsSummary): MetricsHeadline {
    return {
        spendToday: usd(m.spendTodayUsd),
        spendNote: `${usd(m.spendUsd)} in the last ${m.window} · gateway price catalog`,
        tokensToday: compact(m.tokensIn + m.tokensOut),
        tokensNote: `${compact(m.tokensIn)} in · ${compact(m.tokensOut)} out, last ${m.window}`,
        turns24h: compact(m.requests),
        turnsNote: `model requests counted by the gateway, last ${m.window}`,
    };
}

/** A polyline for a sparkline: x from 0 to w, y from h (lowest) to 0 (highest); a flat series sits in the middle. */
export function sparkPath(vals: number[], w: number, h: number): { line: string; last: { x: number; y: number } } {
    if (vals.length === 0) return { line: '', last: { x: 0, y: h } };
    const lo = Math.min(...vals);
    const hi = Math.max(...vals);
    const pts = vals.map((v, i) => ({
        x: vals.length === 1 ? w : (i / (vals.length - 1)) * w,
        y: hi === lo ? h / 2 : h - ((v - lo) / (hi - lo)) * h,
    }));
    const r = (n: number) => +n.toFixed(2);
    return {
        line: pts.map((p, i) => `${i === 0 ? 'M' : 'L'}${r(p.x)},${r(p.y)}`).join(' '),
        last: { x: r(pts[pts.length - 1]!.x), y: r(pts[pts.length - 1]!.y) },
    };
}
