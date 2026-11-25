import { describe, expect, it } from 'vitest';
import { agent, platform } from './fixtures';
import { inUse, posture, recent } from './posture';

describe('posture', () => {
    it('turns the policy into statements with a verdict each', () => {
        const by = Object.fromEntries(posture(platform()).map((i) => [i.id, i]));
        expect(by['profile']?.ok).toBe(true);
        expect(by['egress']?.text).toContain('1 allowed origin');
        expect(by['gate']?.ok).toBe(true);
        expect(by['memory']?.ok).toBe(true);
        expect(by['skills']?.text).toContain('1 approved skill');
        expect(by['max']?.text).toContain('5');
        expect(by['suspend']).toBeUndefined();
    });
    it('warns clearly when the gate is off, the profile is optional or the stop switch is on', () => {
        const p = platform();
        p.gateEnabled = false;
        p.policy.requireToolProfile = false;
        p.policy.suspendAll = true;
        const by = Object.fromEntries(posture(p).map((i) => [i.id, i]));
        expect(by['gate']?.ok).toBe(false);
        expect(by['gate']?.text).toContain('The A2A gate is off');
        expect(by['profile']?.ok).toBe(false);
        expect(by['suspend']?.ok).toBe(false);
    });
    it('warns when memory is allowed but nothing expires it', () => {
        const p = platform();
        p.memory.expiryEnabled = false;
        expect(posture(p).find((i) => i.id === 'memory')?.ok).toBe(false);
    });
});

describe('inUse and recent', () => {
    it('counts the profiles and models the agents really name', () => {
        const l = [
            agent({ name: 'a' }),
            agent({ name: 'b', toolProfile: '', model: 'other', updated: '2026-11-26T10:00:00Z' }),
        ];
        expect(inUse(l, platform())).toEqual({ profiles: 1, profilesOf: 1, models: 1, modelsOf: 1 });
        expect(recent(l, 1).map((a) => a.name)).toEqual(['b']);
    });
});
