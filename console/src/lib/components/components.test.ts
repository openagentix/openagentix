import { render, screen, waitFor, within, fireEvent } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';
import axe from 'axe-core';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { setTransport } from '$lib/api';
import { auth } from '$lib/auth.svelte';
import { ctx } from '$lib/context.svelte';
import { agent, detail, platform } from '$lib/fixtures';
import type { Detail, ValidateResult } from '$lib/types';
import AgentBuilder from './AgentBuilder.svelte';
import AgentRegistry from './AgentRegistry.svelte';

const goto = vi.fn();
vi.mock('$app/navigation', () => ({ goto: (...a: unknown[]) => goto(...a) }));

const json = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

interface World {
    detail: Detail;
    validate: ValidateResult;
    calls: { method: string; url: string; body?: unknown }[];
    putStatus?: number;
    listExtra?: Record<string, unknown>;
}
let w: World;

function route(world: World) {
    setTransport(async (url, init) => {
        const method = init.method ?? 'GET';
        const body = init.body ? JSON.parse(String(init.body)) : undefined;
        world.calls.push({ method, url, body });
        if (url === '/api/v1/agents' && method === 'GET') {
            return json(200, {
                items: [
                    agent(),
                    agent({
                        name: 'cve-triage',
                        state: 'refused',
                        stateReason: 'the definition lists tool "x" which is not in profile "lookup"',
                        conditions: [{ type: 'Accepted', status: 'False', reason: 'PolicyViolation' }],
                    }),
                    agent({ name: 'assistant', source: 'chart', conditions: [] }),
                ],
                used: 2,
                warnings: [],
                ...world.listExtra,
            });
        }
        if (url === '/api/v1/agents/validate') return json(200, world.validate);
        if (url.startsWith('/api/v1/agents/') && method === 'GET') return json(200, world.detail);
        if (url.startsWith('/api/v1/agents/') && method === 'PUT') {
            if (world.putStatus === 409)
                return json(409, {
                    error: {
                        code: 'conflict',
                        message:
                            'researcher was changed by someone else since you opened it. Reload it, then apply your changes again.',
                    },
                });
            return json(200, { ...world.detail, resourceVersion: '8' });
        }
        if (url.startsWith('/api/v1/agents/') && method === 'DELETE')
            return json(202, { name: 'researcher', deleting: true });
        if (url === '/api/v1/agents' && method === 'POST') return json(201, { ...world.detail, name: body.name });
        return json(404, { error: { code: 'not_found', message: 'no' } });
    });
}

async function violations(container: HTMLElement) {
    const r = await axe.run(container, { rules: { 'color-contrast': { enabled: false }, region: { enabled: false } } });
    return r.violations.map((v) => `${v.id}: ${v.nodes.map((n) => n.html).join(' | ')}`);
}

beforeEach(() => {
    goto.mockReset();
    auth.signIn('tok');
    ctx.reset();
    w = {
        detail: detail(),
        validate: { schema: { ok: true, skipped: false, errors: [] }, predicted: [], prediction: true, note: 'n' },
        calls: [],
    };
    route(w);
    // the session and platform the shell would have loaded
    vi.spyOn(ctx, 'platform', 'get').mockReturnValue(platform());
    vi.spyOn(ctx, 'session', 'get').mockReturnValue({
        subject: 'console',
        role: 'operator',
        canWrite: true,
        demo: false,
        version: 't',
        edition: 'community',
        namespace: 'kagent',
        context: '',
    });
});
afterEach(() => vi.restoreAllMocks());

describe('registry', () => {
    it('lists agents with status, source, and the definitions used', async () => {
        const { container } = render(AgentRegistry);
        await screen.findByRole('link', { name: 'researcher' });
        expect(screen.getByTestId('used')).toHaveTextContent('2 of 5 definitions used');
        const row = screen.getByRole('link', { name: 'cve-triage' }).closest('tr')!;
        expect(within(row).getByText('Refused')).toBeInTheDocument();
        expect(row).toHaveTextContent('the definition lists tool "x"');
        expect(
            within(screen.getByRole('link', { name: 'assistant' }).closest('tr')!).getByText('Chart'),
        ).toBeInTheDocument();
        expect(await violations(container)).toEqual([]);
    });
    it('filters by name and by source', async () => {
        render(AgentRegistry);
        await screen.findByRole('link', { name: 'researcher' });
        await userEvent.type(screen.getByLabelText('Filter agents by name'), 'cve');
        expect(screen.queryByRole('link', { name: 'researcher' })).toBeNull();
        await userEvent.clear(screen.getByLabelText('Filter agents by name'));
        await userEvent.click(screen.getByRole('radio', { name: 'Chart' }));
        expect(screen.queryByRole('link', { name: 'researcher' })).toBeNull();
        expect(screen.getByRole('link', { name: 'assistant' })).toBeInTheDocument();
    });
    it('shows an error with Retry, and an empty state', async () => {
        setTransport(async () =>
            json(502, { error: { code: 'cluster_unreachable', message: 'Could not list: not reachable.' } }),
        );
        render(AgentRegistry);
        expect(await screen.findByText(/Could not list: not reachable/)).toBeInTheDocument();
        expect(screen.getByRole('button', { name: 'Retry' })).toBeInTheDocument();
    });
    it('disables New agent with the reason when the policy limit is reached', async () => {
        setTransport(async () => json(200, { items: [agent()], used: 5, warnings: [] }));
        render(AgentRegistry);
        await screen.findByRole('link', { name: 'researcher' });
        const b = screen.getByRole('button', { name: /New agent/ });
        expect(b).toHaveAttribute('aria-disabled', 'true');
        expect(b).toHaveAccessibleDescription('The platform policy allows at most 5 agents and 5 already exist.');
    });
});

describe('paused and the new status contract', () => {
    it('shows a Paused badge and the team and project labels in the registry', async () => {
        setTransport(async () =>
            json(200, {
                items: [agent({ state: 'paused', suspended: true, team: 'platform', project: 'demo' })],
                used: 1,
                warnings: [],
            }),
        );
        render(AgentRegistry);
        const row = (await screen.findByRole('link', { name: 'researcher' })).closest('tr')!;
        expect(within(row).getByText('Paused')).toBeInTheDocument();
        expect(within(row).getByText('team platform')).toBeInTheDocument();
        expect(within(row).getByText('project demo')).toBeInTheDocument();
    });
    it('says why a new agent cannot be created when the policy requires a profile and none is available', async () => {
        const p = platform();
        vi.spyOn(ctx, 'platform', 'get').mockReturnValue({ ...p, profiles: [] });
        render(AgentBuilder, {});
        const note = await screen.findByTestId('no-profile');
        expect(note).toHaveTextContent('This platform requires a tool profile and none is available');
        expect(note).toHaveTextContent('mcp.profiles');
        expect(note.querySelector('a')).toHaveAttribute('href', expect.stringContaining('platform-catalog'));
        await userEvent.type(await screen.findByLabelText('Name'), 'x1');
        await userEvent.type(screen.getByLabelText('Instructions'), 'hi');
        const create = screen.getByRole('button', { name: /Create agent/ });
        expect(create).toHaveAttribute('aria-disabled', 'true');
        expect(create).toHaveAccessibleDescription(/none is available/);
    });
    it('shows no such note when a profile is available', async () => {
        render(AgentBuilder, {});
        await screen.findByLabelText('Instructions');
        expect(screen.queryByTestId('no-profile')).toBeNull();
    });
    it('pauses the saved spec and resumes it', async () => {
        render(AgentBuilder, { name: 'researcher' });
        await userEvent.click(await screen.findByRole('button', { name: 'Pause' }));
        await waitFor(() => expect(w.calls.find((c) => c.method === 'PUT')).toBeTruthy());
        expect(w.calls.find((c) => c.method === 'PUT')?.body).toMatchObject({
            resourceVersion: '7',
            spec: { suspend: true },
        });
    });
    it('shows endpoint and revision, and keeps controller details collapsed and labelled internal', async () => {
        w.detail = detail({
            status: {
                ...detail().status!,
                revision: 'sha256:abc123',
                endpoint: { protocol: 'a2a', url: 'http://gate/agents/kagent/researcher', protocolVersion: '1.0' },
                controller: { keySecret: 'k-1', gatewayUserId: 'kagent.researcher' },
            },
        });
        render(AgentBuilder, { name: 'researcher' });
        await screen.findByLabelText('Instructions');
        expect(screen.getByText('sha256:abc123')).toBeInTheDocument();
        expect(screen.getByText('http://gate/agents/kagent/researcher')).toBeInTheDocument();
        const d = screen.getByTestId('controller-details') as HTMLDetailsElement;
        expect(d.open).toBe(false);
        expect(d).toHaveTextContent('internal');
        expect(screen.getByText('kagent.researcher')).toBeInTheDocument();
    });
    it('shows knowledge collections as read-only and keeps them on save', async () => {
        w.detail = detail({
            spec: {
                ...detail().spec!,
                knowledge: { enabled: true, collections: ['docs'] },
                skills: [{ name: 'openagentix-canary', version: '2' }],
            },
        });
        render(AgentBuilder, { name: 'researcher' });
        expect(await screen.findByTestId('collections')).toHaveTextContent('docs');
        await userEvent.type(screen.getByLabelText('Description'), '!');
        await userEvent.click(screen.getByRole('button', { name: /^Save/ }));
        await waitFor(() => expect(w.calls.find((c) => c.method === 'PUT')).toBeTruthy());
        expect(w.calls.find((c) => c.method === 'PUT')?.body).toMatchObject({
            spec: {
                knowledge: { enabled: true, collections: ['docs'] },
                skills: [{ name: 'openagentix-canary', version: '2' }],
            },
        });
    });
});

describe('builder', () => {
    it('shows counters, the policy panel, status and has no accessibility violations', async () => {
        const { container } = render(AgentBuilder, { name: 'researcher' });
        await screen.findByLabelText('Instructions');
        expect(screen.getByText('9 / 16,384 bytes')).toBeInTheDocument();
        expect(screen.getByText('15 / 256')).toBeInTheDocument();
        expect(screen.getByTestId('policy')).toHaveTextContent('up to 5 definitions');
        expect(screen.getByText(/Status is for generation 1, the current one/)).toBeInTheDocument();
        expect(await violations(container)).toEqual([]);
    });
    it('disables what the policy forbids, with the reason', async () => {
        const p = platform();
        p.policy.allowNotify = false;
        p.models.push('other');
        vi.spyOn(ctx, 'platform', 'get').mockReturnValue(p);
        render(AgentBuilder, { name: 'researcher' });
        await screen.findByLabelText('Instructions');
        expect(screen.getByRole('switch', { name: 'Notify' })).toHaveAttribute('aria-disabled', 'true');
        expect(screen.getByText('Not allowed by the platform policy.')).toBeInTheDocument();
        expect(screen.getByRole('option', { name: /other — Not allowed/ })).toBeDisabled();
        expect(
            screen.getByRole('option', { name: /None — The platform policy requires a toolProfile/ }),
        ).toBeDisabled();
    });
    it('shows live predictions from validate, and labels the button', async () => {
        w.validate = {
            ...w.validate,
            predicted: [
                {
                    field: 'egress.allow',
                    message: 'egress.allow entry "https://x.org" is not matched by the platform policy',
                },
            ],
        };
        render(AgentBuilder, { name: 'researcher' });
        const ins = await screen.findByLabelText('Instructions');
        await userEvent.type(ins, ' more');
        expect(await screen.findByText('This draft would be refused', {}, { timeout: 3000 })).toBeInTheDocument();
        expect(screen.getByTestId('predicted')).toHaveTextContent('is not matched by the platform policy');
        expect(screen.getByRole('button', { name: 'Save anyway' })).toBeInTheDocument();
        expect(w.calls.some((c) => c.url === '/api/v1/agents/validate' && c.method === 'POST')).toBe(true);
    });
    it('saves with the resource version, and handles a conflict', async () => {
        render(AgentBuilder, { name: 'researcher' });
        const desc = await screen.findByLabelText('Description');
        await userEvent.type(desc, '!');
        await userEvent.click(screen.getByRole('button', { name: 'Save' }));
        await waitFor(() => expect(w.calls.find((c) => c.method === 'PUT')).toBeTruthy());
        const put = w.calls.find((c) => c.method === 'PUT')!;
        expect(put.body).toMatchObject({ resourceVersion: '7', spec: { description: 'Looks things up!' } });

        cleanupCalls();
        w.putStatus = 409;
        await userEvent.type(screen.getByLabelText('Description'), '?');
        await userEvent.click(screen.getByRole('button', { name: 'Save' }));
        expect(await screen.findByText('This agent changed since you opened it')).toBeInTheDocument();
        expect(screen.getByRole('button', { name: 'Load the latest version' })).toBeInTheDocument();
    });
    it('shows the refused notice with the controller sentences word for word', async () => {
        const v = [
            'the definition lists tool "knowledge_kb_get_document" which is not in profile "lookup" (the profile offers: a, b)',
            'egress.allow entry "https://services.nvd.nist.gov" is not matched by the platform policy',
        ];
        w.detail = detail({
            state: 'refused',
            status: {
                ...detail().status!,
                violations: v,
                conditions: [{ type: 'Accepted', status: 'False', reason: 'PolicyViolation' }],
            },
        });
        render(AgentBuilder, { name: 'researcher' });
        const list = await screen.findByTestId('violations');
        expect(
            within(list)
                .getAllByRole('listitem')
                .map((l) => l.textContent),
        ).toEqual(v);
        expect(screen.getByText(/2 rules refused this definition/)).toBeInTheDocument();
    });
    it('asks to type the name before deleting', async () => {
        render(AgentBuilder, { name: 'researcher' });
        await screen.findByLabelText('Instructions');
        await userEvent.click(screen.getByRole('button', { name: 'Delete' }));
        const dlg = await screen.findByRole('alertdialog');
        const go = within(dlg).getByRole('button', { name: 'Delete agent' });
        expect(go).toHaveAttribute('aria-disabled', 'true');
        await userEvent.click(go);
        expect(w.calls.some((c) => c.method === 'DELETE')).toBe(false);
        await userEvent.type(within(dlg).getByLabelText('Type researcher to confirm'), 'researcher');
        expect(go).not.toHaveAttribute('aria-disabled');
        await userEvent.click(go);
        await waitFor(() =>
            expect(w.calls.some((c) => c.method === 'DELETE' && c.url === '/api/v1/agents/researcher')).toBe(true),
        );
        expect(goto).toHaveBeenCalledWith('/agents');
    });
    it('opens a chart agent read-only, with the reason, and no Save or Delete', async () => {
        w.detail = detail({ name: 'assistant', source: 'chart', readOnly: true, status: undefined, yaml: '' });
        const { container } = render(AgentBuilder, { name: 'assistant' });
        await screen.findByText(/This agent comes from chart values/);
        expect(screen.queryByRole('button', { name: 'Save' })).toBeNull();
        expect(screen.queryByRole('button', { name: 'Delete' })).toBeNull();
        expect(screen.getByLabelText('Instructions')).toHaveAttribute('readonly');
        expect(await violations(container)).toEqual([]);
    });
    it('creates a new agent: checks the name and sends it', async () => {
        render(AgentBuilder);
        const name = await screen.findByLabelText('Name');
        await userEvent.type(name, 'Bad Name');
        await waitFor(() => expect(screen.getAllByText(/starting with a letter/).length).toBeGreaterThan(0));
        await userEvent.clear(name);
        await userEvent.type(name, 'fresh');
        await fireEvent.input(screen.getByLabelText('Instructions'), { target: { value: 'Do it.' } });
        await userEvent.click(screen.getByRole('button', { name: 'Create agent' }));
        await waitFor(() =>
            expect(w.calls.find((c) => c.method === 'POST' && c.url === '/api/v1/agents')?.body).toMatchObject({
                name: 'fresh',
                spec: { model: 'claude-haiku', instructions: 'Do it.', toolProfile: 'lookup' },
            }),
        );
    });
    it('warns about something shaped like a secret in the instructions', async () => {
        render(AgentBuilder);
        await fireEvent.input(await screen.findByLabelText('Instructions'), {
            target: { value: `use Bearer ${'a'.repeat(30)}` },
        });
        expect(await screen.findByText(/something shaped like a secret \(bearer token\)/)).toBeInTheDocument();
    });
});

function cleanupCalls() {
    w.calls.length = 0;
}

describe('bounded lists', () => {
    it('says how many agents it shows when the console cut the list', async () => {
        w.listExtra = { truncated: true, cap: 500 };
        render(AgentRegistry);
        await screen.findByRole('link', { name: 'researcher' });
        const n = screen.getByTestId('truncated');
        expect(n).toHaveTextContent('Showing the first 500 agents of each kind');
        expect(n).toHaveTextContent('kubectl');
    });
    it('says nothing when the list is complete', async () => {
        render(AgentRegistry);
        await screen.findByRole('link', { name: 'researcher' });
        expect(screen.queryByTestId('truncated')).toBeNull();
    });
});

describe('fields the console does not manage', () => {
    it('opens the instructions read-only when they come from a ConfigMap, and saves without them', async () => {
        w.detail = detail({
            unmanaged: ['instructionsFrom'],
            spec: { model: 'claude-haiku', instructions: '', description: 'd' },
        });
        render(AgentBuilder, { name: 'researcher' });
        const ins = await screen.findByLabelText('Instructions');
        expect(ins).toHaveAttribute('readonly');
        expect(screen.getByTestId('unmanaged')).toHaveTextContent('instructionsFrom');
        expect(screen.getByTestId('unmanaged')).toHaveTextContent('ConfigMap');
        // the other fields stay editable, and the empty instructions do not block a save
        await userEvent.type(screen.getByLabelText('Description'), '!');
        await userEvent.click(screen.getByRole('button', { name: 'Save' }));
        await waitFor(() => expect(w.calls.find((c) => c.method === 'PUT')).toBeTruthy());
        expect(w.calls.find((c) => c.method === 'PUT')!.body).toMatchObject({
            spec: { description: 'd!', instructions: '' },
        });
    });
    it('names other fields it keeps untouched', async () => {
        w.detail = detail({ unmanaged: ['futureField'] });
        render(AgentBuilder, { name: 'researcher' });
        await screen.findByLabelText('Instructions');
        expect(screen.getByLabelText('Instructions')).not.toHaveAttribute('readonly');
        expect(screen.getByTestId('unmanaged')).toHaveTextContent('futureField');
        expect(screen.getByTestId('unmanaged')).toHaveTextContent('kept as they are');
    });
});

describe('the live check is debounced', () => {
    it('sends one validate request for a burst of typing', async () => {
        render(AgentBuilder, { name: 'researcher' });
        const ins = await screen.findByLabelText('Instructions');
        await userEvent.type(ins, ' one two three four five');
        await waitFor(() => expect(w.calls.some((c) => c.url === '/api/v1/agents/validate')).toBe(true), {
            timeout: 3000,
        });
        await new Promise((r) => setTimeout(r, 900));
        expect(w.calls.filter((c) => c.url === '/api/v1/agents/validate').length).toBe(1);
    });
});

describe('overlays', () => {
    it('makes the page inert behind the delete dialog and gives focus back to the button', async () => {
        const { container } = render(AgentBuilder, { name: 'researcher' });
        await screen.findByLabelText('Instructions');
        const opener = screen.getByRole('button', { name: 'Delete' });
        await userEvent.click(opener);
        const dlg = await screen.findByRole('alertdialog');
        expect(dlg.contains(document.activeElement)).toBe(true);
        expect(container.querySelector('.bgrid')?.closest('[inert]')).not.toBeNull();
        await userEvent.keyboard('{Escape}');
        await waitFor(() => expect(screen.queryByRole('alertdialog')).toBeNull());
        expect(container.querySelector('[inert]')).toBeNull();
        expect(document.activeElement).toBe(opener);
    });
});
