// GET /api/v1/traces and /api/v1/traces/{traceId} (services/console/internal/observe), and the layout of the waterfall.
import type { State } from './types';

export interface Turn {
    traceId: string;
    conversationId?: string;
    start: string;
    agent: string;
    outcome: string;
    modelCalls: number;
    durationMs: number;
    tokensIn: number;
    tokensOut: number;
}

export interface Span {
    id: string;
    parentId?: string;
    service: string;
    name: string;
    offsetMs: number;
    durationMs: number;
    error: boolean;
    attrs: Record<string, string>;
}

export interface TraceDetail {
    traceId: string;
    durationMs: number;
    spans: Span[];
}

/** The state colour and word of a turn's outcome (the a2a task state). */
export function outcomeState(o: string): { state: State; word: string } {
    switch (o) {
        case 'completed':
            return { state: 'ready', word: 'Completed' };
        case 'failed':
        case 'error':
            return { state: 'error', word: 'Failed' };
        case 'canceled':
        case 'rejected':
            return { state: 'paused', word: o === 'canceled' ? 'Canceled' : 'Rejected' };
        case 'working':
        case 'submitted':
            return { state: 'pending', word: 'Running' };
        default:
            return { state: 'paused', word: 'Unknown' };
    }
}

export function formatMs(ms: number): string {
    if (ms < 1000) return `${ms} ms`;
    return `${(ms / 1000).toFixed(ms < 10_000 ? 2 : 1)} s`;
}

export interface Row {
    span: Span;
    depth: number;
    /** Bar start and width as percentages of the whole turn. */
    left: number;
    width: number;
}

/** Rows in start order with their depth (from parent ids) and the bar geometry. A span whose parent is missing is a root. */
export function layout(d: TraceDetail): Row[] {
    const total = Math.max(d.durationMs, 1);
    const byId = new Map(d.spans.map((s) => [s.id, s]));
    const depth = (s: Span): number => {
        let n = 0;
        let cur = s;
        const seen = new Set<string>();
        while (cur.parentId && byId.has(cur.parentId) && !seen.has(cur.id) && n < 12) {
            seen.add(cur.id);
            cur = byId.get(cur.parentId)!;
            n++;
        }
        return n;
    };
    return [...d.spans]
        .sort((a, b) => a.offsetMs - b.offsetMs || depth(a) - depth(b))
        .map((s) => ({
            span: s,
            depth: depth(s),
            left: Math.min((s.offsetMs / total) * 100, 99.5),
            width: Math.max(Math.min((s.durationMs / total) * 100, 100 - (s.offsetMs / total) * 100), 0.6),
        }));
}
