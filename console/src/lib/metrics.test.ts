import { describe, expect, it } from 'vitest';
import { compact, headline, sparkPath, usd, type MetricsSummary } from './metrics';

const m: MetricsSummary = {
    window: '24h',
    spendUsd: 0.191,
    spendTodayUsd: 0.074,
    tokensIn: 2.04e6,
    tokensOut: 15100,
    requests: 151,
    cacheReadShare: 0.31,
    byUser: [{ user: 'assistant', costUsd: 0.118, tokensIn: 1, tokensOut: 1, tokensCacheRead: 0 }],
    series: [0, 1, 2, 1],
    generatedAt: '2026-11-25T10:00:00Z',
};

describe('formatting', () => {
    it('writes money and counts compactly', () => {
        expect(usd(0.191)).toBe('$0.191');
        expect(usd(12.3456)).toBe('$12.35');
        expect(usd(0)).toBe('$0');
        expect(compact(2.04e6)).toBe('2.04M');
        expect(compact(15100)).toBe('15.1K');
        expect(compact(63)).toBe('63');
    });
    it('builds the headline tiles from a summary', () => {
        const h = headline(m);
        expect(h.spendToday).toBe('$0.074');
        expect(h.tokensToday).toBe('2.06M');
        expect(h.turns24h).toBe('151');
        expect(h.spendNote).toContain('$0.191');
    });
});

describe('sparkPath', () => {
    it('scales the points into the box', () => {
        const p = sparkPath([0, 2, 1], 100, 20);
        expect(p.line.startsWith('M0,20')).toBe(true);
        expect(p.last).toEqual({ x: 100, y: 10 });
    });
    it('is flat and empty-safe', () => {
        expect(sparkPath([], 100, 20).line).toBe('');
        expect(sparkPath([3, 3], 100, 20).last.y).toBe(10);
    });
});
