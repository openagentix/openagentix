import { render, screen, waitFor, within } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';
import axe from 'axe-core';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { setTransport } from '$lib/api';
import { auth } from '$lib/auth.svelte';
import { ctx } from '$lib/context.svelte';
import { detail, platform } from '$lib/fixtures';
import type { Detail, Platform, ValidateResult } from '$lib/types';
import AgentBuilder from './AgentBuilder.svelte';
import ContainerAgentForm from './ContainerAgentForm.svelte';

const goto = vi.fn();
vi.mock('$app/navigation', () => ({ goto: (...a: unknown[]) => goto(...a) }));

const json = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

const DIGEST = 'sha256:' + 'b'.repeat(64);
const GOOD = `registry.example.com/agents/echo@${DIGEST}`;
const OK: ValidateResult = {
    schema: { ok: true, skipped: false, errors: [] },
    predicted: [],
    prediction: true,
    note: 'n',
};

interface World {
    validate: ValidateResult;
    created?: Detail;
    createStatus?: number;
    calls: { method: string; url: string; body?: { name?: string; spec?: Record<string, unknown> } }[];
}
let w: World;

function route() {
    setTransport(async (url, init) => {
        const method = init.method ?? 'GET';
        const body = init.body ? JSON.parse(String(init.body)) : undefined;
        w.calls.push({ method, url, body });
        if (url === '/api/v1/agents/validate') return json(200, w.validate);
        if (url === '/api/v1/agents' && method === 'POST') {
            if (w.createStatus === 422)
                return json(422, {
                    error: {
                        code: 'invalid',
                        message: 'The platform would refuse this agent, so it was not created: x.',
                    },
                });
            return json(201, { ...detail(), name: body.name });
        }
        return json(404, { error: { code: 'not_found', message: 'no' } });
    });
}

function setPlatform(p: Platform = platform(), canWrite = true) {
    vi.spyOn(ctx, 'platform', 'get').mockReturnValue(p);
    vi.spyOn(ctx, 'session', 'get').mockReturnValue({
        subject: 'console',
        role: canWrite ? 'operator' : 'viewer',
        canWrite,
        demo: false,
        version: 't',
        edition: 'community',
        namespace: 'kagent',
        context: '',
    });
}

beforeEach(() => {
    goto.mockReset();
    auth.signIn('tok');
    ctx.reset();
    w = { validate: OK, calls: [] };
    route();
    setPlatform();
});
afterEach(() => vi.restoreAllMocks());

const validates = () => w.calls.filter((c) => c.url === '/api/v1/agents/validate');
async function fill(name = 'echo', image = GOOD) {
    await userEvent.type(screen.getByLabelText('Name'), name);
    await userEvent.type(screen.getByLabelText('Image'), image);
}

describe('bring your own agent', () => {
    it('shows an image field with an example and the digest rule, and no instructions field', async () => {
        const { container } = render(ContainerAgentForm);
        expect(await screen.findByRole('heading', { name: 'Bring your own agent' })).toBeInTheDocument();
        expect(screen.getByLabelText('Image')).toBeInTheDocument();
        expect(screen.getByText(/registry\.example\.com\/agents\/my-agent@sha256:<64 hex digits>/)).toBeInTheDocument();
        expect(screen.getByText(/must be pinned by digest/i)).toBeInTheDocument();
        expect(screen.queryByLabelText('Instructions')).toBeNull();
        expect(screen.getByLabelText('Port')).toHaveValue('8080');
        // the honest isolation note
        expect(screen.getByRole('heading', { name: /less isolated than a built-in agent/i })).toBeInTheDocument();
        const axeResult = await axe.run(container, {
            rules: { 'color-contrast': { enabled: false }, region: { enabled: false } },
        });
        expect(axeResult.violations.map((v) => v.id)).toEqual([]);
    });

    it('lists only models the policy allows and only tool profiles open to container agents', async () => {
        const p = platform();
        p.models.push('other');
        p.profiles.push({ name: 'closed', toolServer: 's', codeMode: false, tools: ['x'], containerAccess: false });
        p.policy.allowedProfiles.push('closed');
        setPlatform(p);
        render(ContainerAgentForm);
        await screen.findByLabelText('Image');
        expect(screen.getByRole('option', { name: /other — Not allowed/ })).toBeDisabled();
        expect(screen.getByRole('option', { name: /closed — Not open to container agents/ })).toBeDisabled();
        expect(screen.getByRole('option', { name: 'lookup' })).toBeEnabled();
    });

    it('says in plain English what is wrong with a tag, and does not call the server for it', async () => {
        render(ContainerAgentForm);
        await fill('echo', 'registry.example.com/agents/echo:latest');
        expect(
            await screen.findByText(/The image must be pinned by digest, for example/, { selector: '.err span' }),
        ).toBeInTheDocument();
        expect(screen.getByRole('button', { name: 'Create agent' })).toHaveAttribute('aria-disabled', 'true');
        await new Promise((r) => setTimeout(r, 900));
        expect(validates()).toHaveLength(0);
    });

    it('refuses an image from another registry and names the allowed one', async () => {
        render(ContainerAgentForm);
        await fill('echo', `evil.example.com/x@${DIGEST}`);
        expect(
            await screen.findByText(/not under a registry the platform policy allows/, { selector: '.err span' }),
        ).toBeInTheDocument();
        expect(screen.getByText(/registry\.example\.com\/agents\//, { selector: '.err span' })).toBeInTheDocument();
    });

    it('checks the port and the variable names', async () => {
        render(ContainerAgentForm);
        const port = screen.getByLabelText('Port');
        await userEvent.clear(port);
        await userEvent.type(port, '80');
        expect(await screen.findByText(/whole number from 1024 to 65535/)).toBeInTheDocument();
        await userEvent.click(screen.getByRole('button', { name: 'Add variable' }));
        await userEvent.type(screen.getByLabelText('Variable 1 name'), 'OPENAI_BASE_URL');
        expect(await screen.findByText(/OPENAI_BASE_URL is reserved/)).toBeInTheDocument();
    });

    it('never shows a secret-shaped value, and never sends it to the server', async () => {
        render(ContainerAgentForm);
        await fill();
        await userEvent.click(screen.getByRole('button', { name: 'Add variable' }));
        await userEvent.type(screen.getByLabelText('Variable 1 name'), 'TOKEN');
        const secret = 'sk-' + 'a'.repeat(40);
        await userEvent.type(screen.getByLabelText('Variable 1 value'), secret);
        expect(
            await screen.findByText(/shaped like a secret \(provider secret key\)/, { selector: '.err span' }),
        ).toBeInTheDocument();
        // the message does not repeat the value (the input holds what the user typed)
        const err = screen.getByText(/shaped like a secret/, { selector: '.err span' });
        expect(err.textContent).not.toContain(secret);
        await new Promise((r) => setTimeout(r, 900));
        expect(JSON.stringify(w.calls)).not.toContain(secret);
        expect(screen.getByRole('button', { name: 'Create agent' })).toHaveAttribute('aria-disabled', 'true');
        expect(JSON.stringify(localStorage)).not.toContain(secret);
    });

    it('does not create until the server check has passed, then creates with a runtime and no instructions', async () => {
        render(ContainerAgentForm);
        const create = screen.getByRole('button', { name: 'Create agent' });
        expect(create).toHaveAttribute('aria-disabled', 'true');
        await fill();
        await waitFor(() => expect(validates().length).toBeGreaterThan(0), { timeout: 3000 });
        expect(validates().at(-1)?.body).toMatchObject({
            name: 'echo',
            spec: { model: 'claude-haiku', runtime: { type: 'container', container: { image: GOOD, port: 8080 } } },
        });
        expect(validates().at(-1)?.body?.spec).not.toHaveProperty('instructions');
        await waitFor(() =>
            expect(screen.getByRole('button', { name: 'Create agent' })).not.toHaveAttribute('aria-disabled', 'true'),
        );
        await userEvent.click(screen.getByRole('button', { name: 'Create agent' }));
        await waitFor(() => expect(w.calls.some((c) => c.method === 'POST' && c.url === '/api/v1/agents')).toBe(true));
        const post = w.calls.find((c) => c.method === 'POST' && c.url === '/api/v1/agents')!;
        expect(post.body).toMatchObject({ name: 'echo', spec: { runtime: { type: 'container' } } });
        expect(post.body?.spec).not.toHaveProperty('instructions');
        await waitFor(() => expect(goto).toHaveBeenCalledWith('/agents/echo', { replaceState: true }));
        // the check came before the create
        const order = w.calls.map((c) => (c.url.endsWith('validate') ? 'validate' : c.method));
        expect(order.indexOf('validate')).toBeLessThan(order.indexOf('POST'));
    });

    it('keeps Create off and shows the sentences when the platform would refuse', async () => {
        w.validate = {
            ...OK,
            predicted: [
                {
                    field: 'runtime.container.image',
                    message: 'runtime.container.image "x" is not under a registry prefix the platform policy allows',
                },
            ],
        };
        render(ContainerAgentForm);
        await fill();
        expect(await screen.findByText('This agent would be refused', {}, { timeout: 3000 })).toBeInTheDocument();
        expect(screen.getByTestId('predicted')).toHaveTextContent('is not under a registry prefix');
        expect(screen.getByRole('button', { name: 'Create agent' })).toHaveAttribute('aria-disabled', 'true');
    });

    it('shows the Kubernetes API refusal in the check, and keeps Create off', async () => {
        w.validate = {
            ...OK,
            schema: { ok: false, skipped: false, errors: ['spec.runtime.container.port: Invalid value'] },
        };
        render(ContainerAgentForm);
        await fill();
        expect(
            await screen.findByText('The Kubernetes API would refuse this', {}, { timeout: 3000 }),
        ).toBeInTheDocument();
        expect(screen.getByRole('button', { name: 'Create agent' })).toHaveAttribute('aria-disabled', 'true');
    });

    it('shows the server refusal of a create', async () => {
        w.createStatus = 422;
        render(ContainerAgentForm);
        await fill();
        await waitFor(
            () =>
                expect(screen.getByRole('button', { name: 'Create agent' })).not.toHaveAttribute(
                    'aria-disabled',
                    'true',
                ),
            { timeout: 3000 },
        );
        await userEvent.click(screen.getByRole('button', { name: 'Create agent' }));
        expect(await screen.findByText('Not created')).toBeInTheDocument();
        expect(goto).not.toHaveBeenCalled();
    });

    it('explains why it is off when the platform has no container runtime, the policy refuses it, or no registry is allowed', async () => {
        for (const [mut, text] of [
            [(p: Platform) => (p.container.available = false), /not installed on this platform/],
            [(p: Platform) => (p.container.allowed = false), /policy does not allow container agents/],
            [(p: Platform) => (p.container.images = []), /allows no image registry/],
        ] as [(p: Platform) => void, RegExp][]) {
            const p = platform();
            mut(p);
            setPlatform(p);
            const { unmount } = render(ContainerAgentForm);
            expect(await screen.findByText(text)).toBeInTheDocument();
            expect(screen.queryByLabelText('Image')).toBeNull();
            unmount();
        }
    });

    it('is read-only in a viewer console', async () => {
        setPlatform(platform(), false);
        render(ContainerAgentForm);
        expect(await screen.findByText('This console is read-only')).toBeInTheDocument();
        expect(screen.queryByRole('button', { name: 'Create agent' })).toBeNull();
    });
});

describe('the builder and container agents', () => {
    it('links to the path from the new agent page', async () => {
        render(AgentBuilder);
        const link = await screen.findByRole('link', { name: 'Bring your own agent' });
        expect(link).toHaveAttribute('href', '/agents/new/container');
    });

    it('does not offer the link when container agents are off', async () => {
        const p = platform();
        p.container.allowed = false;
        setPlatform(p);
        render(AgentBuilder);
        await screen.findByLabelText('Instructions');
        expect(screen.queryByRole('link', { name: 'Bring your own agent' })).toBeNull();
    });

    it('opens a container agent read-only, with its image, so a save cannot drop it', async () => {
        const d = detail({
            runtimeType: 'container',
            spec: {
                model: 'claude-haiku',
                runtime: { type: 'container', container: { image: GOOD, port: 8080 } },
            },
        });
        setTransport(async (url) =>
            url.startsWith('/api/v1/agents/') ? json(200, d) : json(404, { error: { code: 'x', message: 'x' } }),
        );
        render(AgentBuilder, { name: 'researcher' });
        const note = await screen.findByTestId('container-note');
        expect(screen.getByText('This is a container agent')).toBeInTheDocument();
        expect(within(note).getByText(/It runs your own image/)).toBeInTheDocument();
        expect(note).toHaveTextContent(GOOD);
        expect(screen.queryByRole('button', { name: 'Save' })).toBeNull();
        expect(screen.queryByLabelText('Instructions')).toBeNull();
    });
});
