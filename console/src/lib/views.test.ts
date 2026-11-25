import { describe, expect, it } from 'vitest';
import { agent, platform } from './fixtures';
import { attention, contextLine, countStates, platformRows, policyYaml, shortRef, ttlLine, usedBy } from './views';

describe('shortRef', () => {
    it('keeps the repository and shortens the digest', () => {
        const full = `registry.invalid:5000/skills/x@sha256:9c1e${'a'.repeat(52)}b07d`;
        expect(shortRef(full)).toBe('registry.invalid:5000/skills/x@sha256:9c1e…b07d');
    });
    it('leaves a reference without a digest alone', () => {
        expect(shortRef('registry/x:1.0')).toBe('registry/x:1.0');
    });
});

describe('contextLine', () => {
    it('shows only the namespace when the API names no context', () => {
        expect(contextLine({ context: '', namespace: 'kagent' })).toBe('kagent');
    });
    it('adds the namespace after the context', () => {
        expect(contextLine({ context: 'kind-openagentix', namespace: 'kagent' })).toBe('kind-openagentix · kagent');
    });
    it('does not repeat a namespace the context text already holds', () => {
        expect(contextLine({ context: 'kind-openagentix · kagent', namespace: 'kagent' })).toBe(
            'kind-openagentix · kagent',
        );
    });
    it('is empty with neither', () => {
        expect(contextLine(null)).toBe('');
    });
});

describe('countStates', () => {
    it('counts states, chart agents and the definitions', () => {
        const c = countStates([
            agent({ name: 'a' }),
            agent({ name: 'b', state: 'pending' }),
            agent({ name: 'c', state: 'refused' }),
            agent({ name: 'd', state: 'paused', suspended: true }),
            agent({ name: 'e', source: 'chart' }),
        ]);
        expect(c).toMatchObject({
            total: 5,
            ready: 2,
            pending: 1,
            refused: 1,
            paused: 1,
            error: 0,
            chart: 1,
            built: 4,
        });
    });
});

describe('attention', () => {
    it('lists what is not Ready with its reason, refused first', () => {
        const a = attention([
            agent({ name: 'ok' }),
            agent({ name: 'slow', state: 'pending', stateReason: 'waiting for the runtime' }),
            agent({ name: 'bad', state: 'refused', stateReason: 'first sentence' }),
        ]);
        expect(a.map((x) => x.name)).toEqual(['bad', 'slow']);
        expect(a[0]?.reason).toBe('first sentence');
    });
});

describe('usedBy', () => {
    it('lists agent names sorted', () => {
        const l = [
            agent({ name: 'b', model: 'm' }),
            agent({ name: 'a', model: 'm' }),
            agent({ name: 'c', model: 'x' }),
        ];
        expect(usedBy(l, (x) => x.model === 'm')).toEqual(['a', 'b']);
    });
});

describe('ttlLine', () => {
    it('names the default and the maximum', () => {
        expect(ttlLine(platform())).toBe('15 days by default, at most 30 days');
    });
});

describe('platformRows', () => {
    it('describes each component in plain words, from the catalog only', () => {
        const by = Object.fromEntries(platformRows(platform()).map((r) => [r.label, r]));
        expect(by['Runtime']?.value).toBe('kagent');
        expect(by['Memory']?.on).toBe(true);
        expect(by['Memory']?.note).toContain('expiry job on');
        expect(by['A2A gate']?.on).toBe(true);
        const p = platform();
        p.gateEnabled = false;
        p.knowledge.available = false;
        const off = Object.fromEntries(platformRows(p).map((r) => [r.label, r]));
        expect(off['A2A gate']?.on).toBe(false);
        expect(off['Knowledge']?.on).toBe(false);
    });
});

describe('policyYaml', () => {
    it('writes the policy in the order of the control-plane README', () => {
        const y = policyYaml(platform().policy);
        expect(y.split('\n').slice(0, 3)).toEqual(['maxAgents: 5', 'allowedModels:', '  - claude-haiku']);
        expect(y).toContain('memory:\n  allowed: true\n  maxTtlDays: 30\n  requireExpiry: true');
        expect(y).toContain('egress:\n  allowedOrigins:\n    - https://api.osv.dev');
        expect(y).toContain('suspendAll: false');
    });
    it('writes an empty list as []', () => {
        expect(policyYaml(platform().policy)).toContain('reservedNames: []');
    });
});
