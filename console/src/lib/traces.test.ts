import { describe, expect, it } from 'vitest';
import { formatMs, layout, outcomeState, type TraceDetail } from './traces';

const span = (id: string, parentId: string | undefined, offsetMs: number, durationMs: number) => ({
    id,
    parentId,
    service: 's',
    name: id,
    offsetMs,
    durationMs,
    error: false,
    attrs: {},
});

describe('layout', () => {
    const d: TraceDetail = {
        traceId: 'x',
        durationMs: 1000,
        spans: [
            span('b', 'a', 100, 500),
            span('a', undefined, 0, 1000),
            span('c', 'b', 200, 100),
            span('z', 'missing', 900, 100),
        ],
    };
    it('orders by start and nests by parent', () => {
        const rows = layout(d);
        expect(rows.map((r) => [r.span.id, r.depth])).toEqual([
            ['a', 0],
            ['b', 1],
            ['c', 2],
            ['z', 0],
        ]);
    });
    it('turns offsets into percentages that stay inside the bar', () => {
        const r = layout(d).find((x) => x.span.id === 'b')!;
        expect(r.left).toBe(10);
        expect(r.width).toBe(50);
        expect(layout(d).every((x) => x.left + x.width <= 100.0001)).toBe(true);
    });
    it('survives a cycle and a zero duration', () => {
        const rows = layout({ traceId: 'x', durationMs: 0, spans: [span('p', 'q', 0, 0), span('q', 'p', 0, 0)] });
        expect(rows).toHaveLength(2);
    });
});

describe('words', () => {
    it('maps outcomes to a state and a word', () => {
        expect(outcomeState('completed')).toEqual({ state: 'ready', word: 'Completed' });
        expect(outcomeState('failed').state).toBe('error');
        expect(outcomeState('weird').word).toBe('Unknown');
    });
    it('formats durations', () => {
        expect(formatMs(480)).toBe('480 ms');
        expect(formatMs(3200)).toBe('3.20 s');
        expect(formatMs(12400)).toBe('12.4 s');
    });
});
