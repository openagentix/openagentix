import { describe, expect, it } from 'vitest';
import { MARKS, NAV } from './nav';

const marks = () => Object.fromEntries(NAV.flatMap((g) => g.items).map((i) => [i.id, i.mark ?? 'none']));

describe('sidebar markers', () => {
    it('marks the pages that show real data as read-only', () => {
        const m = marks();
        for (const id of ['models', 'tools', 'skills', 'memory', 'governance']) expect(m[id], id).toBe('readonly');
    });
    it('marks the pages without a data source differently', () => {
        const m = marks();
        for (const id of ['knowledge', 'channels', 'schedules']) expect(m[id], id).toBe('nodata');
    });
    it('marks nothing on Overview and Agents, which are live', () => {
        const m = marks();
        expect(m['overview']).toBe('none');
        expect(m['agents']).toBe('none');
    });
    it('gives the two markers different icons and words', () => {
        expect(MARKS.readonly.icon).not.toBe(MARKS.nodata.icon);
        expect(MARKS.readonly.legend).not.toBe(MARKS.nodata.legend);
    });
});
