import { describe, expect, it } from 'vitest';
import {
    containerAvailability,
    containerProblems,
    containerProfileOptions,
    containerSpec,
    emptyContainerDraft,
    imageExample,
    type ContainerDraft,
} from './container';
import { platform } from './fixtures';

const DIGEST = 'sha256:' + 'a'.repeat(64);
const GOOD = `registry.example.com/agents/echo@${DIGEST}`;

function draft(over: Partial<ContainerDraft> = {}): ContainerDraft {
    return { ...emptyContainerDraft(platform()), name: 'echo', image: GOOD, ...over };
}

describe('the draft of a container agent', () => {
    it('starts with the first allowed model, port 8080 and no tool profile', () => {
        const d = emptyContainerDraft(platform());
        expect(d).toMatchObject({ name: '', model: 'claude-haiku', image: '', port: '8080', env: [], toolProfile: '' });
    });

    it('becomes a spec with a runtime and no instructions', () => {
        const s = containerSpec(draft({ description: ' Mine ', env: [{ name: 'LOG_LEVEL', value: 'info' }] }));
        expect(s).toEqual({
            model: 'claude-haiku',
            description: 'Mine',
            runtime: {
                type: 'container',
                container: { image: GOOD, port: 8080, env: [{ name: 'LOG_LEVEL', value: 'info' }] },
            },
        });
        expect('instructions' in s).toBe(false);
    });

    it('leaves out what is empty: no env, no profile, no description, blank env rows', () => {
        const s = containerSpec(draft({ env: [{ name: '', value: '' }] }));
        expect(s.runtime?.container).toEqual({ image: GOOD, port: 8080 });
        expect(s.toolProfile).toBeUndefined();
        expect(s.description).toBeUndefined();
        expect(containerSpec(draft({ toolProfile: 'lookup' })).toolProfile).toBe('lookup');
    });

    it('trims the image', () => {
        expect(containerSpec(draft({ image: `  ${GOOD} ` })).runtime?.container?.image).toBe(GOOD);
    });
});

describe('the rules, in plain English, as the platform guard has them', () => {
    const p = platform();
    it('accepts a digest-pinned image under an allowed registry', () => {
        expect(containerProblems(draft(), p)).toEqual({});
    });

    it('asks for an image', () => {
        expect(containerProblems(draft({ image: '' }), p).image).toMatch(/Enter the image/);
    });

    it('refuses a tag and shows an example with the digest and how to find it', () => {
        const m = containerProblems(draft({ image: 'registry.example.com/agents/echo:latest' }), p).image ?? '';
        expect(m).toMatch(/pinned by digest/);
        expect(m).toMatch(/not a tag/i);
        expect(m).toContain('@sha256:');
    });

    it('refuses a tag next to the digest', () => {
        const m = containerProblems(draft({ image: `registry.example.com/agents/echo:1.0@${DIGEST}` }), p).image ?? '';
        expect(m).toMatch(/Remove the tag/);
    });

    it('refuses a short or upper case digest', () => {
        expect(containerProblems(draft({ image: 'registry.example.com/agents/echo@sha256:abc' }), p).image).toMatch(
            /64 lower case hex/,
        );
    });

    it('refuses an image from a registry the policy does not allow, and names the allowed ones', () => {
        const m = containerProblems(draft({ image: `evil.example.com/x@${DIGEST}` }), p).image ?? '';
        expect(m).toMatch(/not under a registry/);
        expect(m).toContain('registry.example.com/agents/');
    });

    it('says plainly when the policy allows no registry at all', () => {
        const q = platform();
        q.container.images = [];
        expect(containerProblems(draft(), q).image).toMatch(/no image registry/);
    });

    it('checks the port', () => {
        for (const bad of ['', 'x', '80', '1023', '65536', '8080.5', '-1']) {
            expect(containerProblems(draft({ port: bad }), p).port, bad).toMatch(/1024 to 65535/);
        }
        expect(containerProblems(draft({ port: '1024' }), p).port).toBeUndefined();
        expect(containerProblems(draft({ port: '65535' }), p).port).toBeUndefined();
    });

    it('checks the environment names', () => {
        const env = (name: string, value = 'x') => draft({ env: [{ name, value }] });
        expect(containerProblems(env('log_level'), p).env).toMatch(/upper case/);
        expect(containerProblems(env('1X'), p).env).toMatch(/upper case/);
        expect(containerProblems(env('OPENAI_BASE_URL'), p).env).toMatch(/reserved/);
        expect(containerProblems(env('OPENAGENTIX_X'), p).env).toMatch(/reserved/);
        expect(containerProblems(env('OTEL_X'), p).env).toMatch(/reserved/);
        expect(containerProblems(env('KUBERNETES_X'), p).env).toMatch(/reserved/);
        expect(containerProblems(env('LOG_LEVEL'), p).env).toBeUndefined();
        expect(
            containerProblems(
                draft({
                    env: [
                        { name: 'A', value: '1' },
                        { name: 'A', value: '2' },
                    ],
                }),
                p,
            ).env,
        ).toMatch(/twice/);
    });

    it('refuses a value shaped like a secret, without printing it', () => {
        const secret = 'sk-' + 'a'.repeat(40);
        const m = containerProblems(draft({ env: [{ name: 'TOKEN', value: secret }] }), p).env ?? '';
        expect(m).toMatch(/shaped like a secret/);
        expect(m).toMatch(/provider secret key/);
        expect(m).not.toContain(secret);
    });

    it('limits the number and size of values', () => {
        const many = Array.from({ length: 33 }, (_, i) => ({ name: `V${i}`, value: 'x' }));
        expect(containerProblems(draft({ env: many }), p).env).toMatch(/At most 32/);
        expect(containerProblems(draft({ env: [{ name: 'BIG', value: 'a'.repeat(4097) }] }), p).env).toMatch(/4096/);
    });

    it('needs a name that is a DNS label, and a model the policy allows', () => {
        expect(containerProblems(draft({ name: 'Bad_Name' }), p).name).toMatch(/lower case/);
        expect(containerProblems(draft({ model: '' }), p).model).toMatch(/Choose a model/);
        expect(containerProblems(draft({ model: 'other' }), p).model).toMatch(/not allowed/);
    });

    it('allows a tool profile only when it is allowed and open to container agents', () => {
        expect(containerProblems(draft({ toolProfile: 'lookup' }), p).toolProfile).toBeUndefined();
        const q = platform();
        q.profiles[0]!.containerAccess = false;
        expect(containerProblems(draft({ toolProfile: 'lookup' }), q).toolProfile).toMatch(
            /not open to container agents/,
        );
        expect(containerProblems(draft({ toolProfile: 'nope' }), p).toolProfile).toMatch(/not defined/);
        const r = platform();
        r.policy.allowedProfiles = [];
        expect(containerProblems(draft({ toolProfile: 'lookup' }), r).toolProfile).toMatch(/not allowed/);
    });
});

describe('whether the path is offered', () => {
    it('is on when installed and allowed, with a registry', () => {
        expect(containerAvailability(platform())).toEqual({ ok: true });
    });
    it('says the platform has no container runtime', () => {
        const p = platform();
        p.container.available = false;
        expect(containerAvailability(p)).toEqual({ ok: false, reason: expect.stringMatching(/not installed/) });
    });
    it('says the policy does not allow it', () => {
        const p = platform();
        p.container.allowed = false;
        expect(containerAvailability(p)).toEqual({ ok: false, reason: expect.stringMatching(/policy does not allow/) });
    });
    it('says no registry is allowed', () => {
        const p = platform();
        p.container.images = [];
        expect(containerAvailability(p)).toEqual({ ok: false, reason: expect.stringMatching(/no image registry/) });
    });
});

describe('options', () => {
    it('offers a tool profile only from allowedProfiles that are open to container agents', () => {
        const p = platform();
        p.policy.allowedProfiles.push('closed');
        p.profiles.push({ name: 'closed', toolServer: 's', codeMode: false, tools: ['x'], containerAccess: false });
        p.profiles.push({ name: 'blocked', toolServer: 's', codeMode: false, tools: ['y'], containerAccess: true });
        const o = containerProfileOptions(p);
        expect(o[0]).toMatchObject({ value: '', label: 'None', disabled: false });
        expect(o.find((x) => x.value === 'lookup')?.disabled).toBe(false);
        expect(o.find((x) => x.value === 'closed')).toMatchObject({
            disabled: true,
            reason: expect.stringMatching(/not open to container agents/i),
        });
        expect(o.find((x) => x.value === 'blocked')).toMatchObject({
            disabled: true,
            reason: expect.stringMatching(/not allowed/i),
        });
    });

    it('builds the example from the first allowed registry', () => {
        expect(imageExample(platform())).toBe('registry.example.com/agents/my-agent@sha256:<64 hex digits>');
        const p = platform();
        p.container.images = [];
        expect(imageExample(p)).toBe('registry.example.com/team/my-agent@sha256:<64 hex digits>');
    });
});
