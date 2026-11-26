import { describe, expect, it } from 'vitest';
import { allows, emptyDraft, modelOptions, noProfileAvailable, profileOptions, skillStates } from './draft';
import { platform } from './fixtures';
import type { Platform } from './types';

function withPolicy(over: Partial<Platform['policy']>, rest: Partial<Platform> = {}): Platform {
    const p = platform();
    return { ...p, ...rest, policy: { ...p.policy, ...over } };
}

describe('the policy wildcard', () => {
    it('allows every name for the single entry *, and none for an empty list', () => {
        expect(allows(['*'], 'anything')).toBe(true);
        expect(allows(['a'], 'a')).toBe(true);
        expect(allows(['a'], 'b')).toBe(false);
        expect(allows([], 'a')).toBe(false);
    });
    it('opens models, profiles and skills in the builder choices', () => {
        const p = withPolicy({ allowedModels: ['*'], allowedProfiles: ['*'], allowedSkills: ['*'] });
        expect(modelOptions(p).every((o) => !o.disabled)).toBe(true);
        expect(
            profileOptions(p)
                .filter((o) => o.value)
                .every((o) => !o.disabled),
        ).toBe(true);
        expect(skillStates(p).every((s) => !s.disabled)).toBe(true);
        expect(emptyDraft(p).toolProfile).toBe('lookup');
    });
});

describe('a required tool profile that nobody can pick', () => {
    it('is not reported when a listed profile exists', () => {
        expect(noProfileAvailable(platform())).toBeUndefined();
    });
    it('is reported when the catalog has no profile at all', () => {
        const msg = noProfileAvailable(withPolicy({}, { profiles: [] }));
        expect(msg).toMatch(/requires a tool profile and none is available/);
        expect(msg).toMatch(/mcp\.profiles/);
        expect(msg).not.toMatch(/—/);
    });
    it('is reported when no catalog profile is allowed by the policy', () => {
        expect(noProfileAvailable(withPolicy({ allowedProfiles: ['other'] }))).toBeDefined();
        expect(noProfileAvailable(withPolicy({ allowedProfiles: [] }))).toBeDefined();
    });
    it('is not reported when the policy does not require a profile', () => {
        expect(noProfileAvailable(withPolicy({ requireToolProfile: false }, { profiles: [] }))).toBeUndefined();
    });
});
