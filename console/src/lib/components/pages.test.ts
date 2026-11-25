import { render, screen, waitFor, within } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';
import axe from 'axe-core';
import { beforeEach, describe, expect, it } from 'vitest';
import { setTransport } from '$lib/api';
import { auth } from '$lib/auth.svelte';
import { ctx } from '$lib/context.svelte';
import { agent, platform } from '$lib/fixtures';
import type { Agent, Platform } from '$lib/types';
import GovernancePage from './GovernancePage.svelte';
import MemoryPage from './MemoryPage.svelte';
import ModelsPage from './ModelsPage.svelte';
import OverviewPage from './OverviewPage.svelte';
import SkillsPage from './SkillsPage.svelte';
import ToolsPage from './ToolsPage.svelte';

const json = (body: unknown) =>
    new Response(JSON.stringify(body), { status: 200, headers: { 'Content-Type': 'application/json' } });

const FULL = `registry.invalid:5000/skills/openagentix-canary@sha256:9c1e${'a'.repeat(52)}b07d`;

function world(over: { platform?: Partial<Platform>; agents?: Agent[]; extra?: Record<string, unknown> } = {}) {
    const p: Platform = {
        ...platform(),
        models: ['claude-haiku', 'claude-sonnet'],
        profiles: [
            ...platform().profiles,
            { name: 'browse', toolServer: 'toolhive-vmcp-browse', codeMode: false, tools: ['fetch_fetch'] },
        ],
        skills: [
            { name: 'openagentix-canary', ref: FULL },
            { name: 'openagentix-triage', ref: 'r2' },
        ],
        ...over.platform,
    };
    const agents = over.agents ?? [
        agent({
            name: 'researcher',
            effectiveTools: ['osv_query_vulnerability'],
            effectiveEgress: ['https://api.osv.dev'],
            skills: ['openagentix-canary'],
            memory: { enabled: true, ttlDays: 20 },
        }),
        agent({
            name: 'cve-triage',
            state: 'refused',
            stateReason: 'the definition lists tool "x" which is not in profile "lookup"',
        }),
        agent({ name: 'release-notes', state: 'pending', stateReason: 'AgentPending: no Ready condition yet' }),
        agent({ name: 'napper', state: 'paused', suspended: true, stateReason: 'suspended' }),
        agent({
            name: 'assistant',
            source: 'chart',
            model: 'claude-sonnet',
            toolProfile: '',
            memory: { enabled: true, ttlDays: 30 },
        }),
    ];
    setTransport(async (url) => {
        if (url === '/api/v1/session')
            return json({
                subject: 'console',
                role: 'operator',
                canWrite: true,
                demo: false,
                version: 'v',
                edition: 'community',
                namespace: 'kagent',
                context: '',
            });
        if (url === '/api/v1/platform') return json(p);
        if (url === '/api/v1/agents')
            return json({
                items: agents,
                used: agents.filter((a) => a.source === 'built').length,
                warnings: [],
                ...over.extra,
            });
        return new Response('{}', { status: 404 });
    });
}

beforeEach(async () => {
    auth.signIn('tok');
    ctx.reset();
});

async function load() {
    await ctx.load();
}

describe('Overview', () => {
    it('shows real tiles, what needs attention, the platform and the policy', async () => {
        world();
        await load();
        render(OverviewPage);
        const tiles = await screen.findByRole('group', { name: 'Totals' });
        expect(within(tiles).getByText('Agents').closest('.tile')).toHaveTextContent('5');
        expect(tiles).toHaveTextContent('2 ready');
        expect(tiles).toHaveTextContent('1 pending');
        expect(tiles).toHaveTextContent('1 refused');
        expect(tiles).toHaveTextContent('1 paused');
        expect(tiles).toHaveTextContent('1 chart-managed');
        expect(within(tiles).getByText('Definitions used').closest('.tile')).toHaveTextContent('4of 5');
        const att = screen.getByRole('region', { name: 'Needs attention' });
        expect(within(att).getByRole('link', { name: 'cve-triage' })).toHaveAttribute('href', '/agents/cve-triage');
        expect(att).toHaveTextContent('which is not in profile "lookup"');
        expect(att).toHaveTextContent('AgentPending');
        expect(att).not.toHaveTextContent('researcher');
        const plat = screen.getByRole('region', { name: 'Platform' });
        expect(plat).toHaveTextContent('kagent');
        expect(plat).toHaveTextContent('A2A gate');
        expect(plat).toHaveTextContent('expiry job on');
        expect(screen.getByRole('region', { name: 'Platform policy' })).toBeInTheDocument();
        expect(screen.getByRole('link', { name: /Governance/ })).toHaveAttribute('href', '/governance');
    });
    it('shows no empty-state banner and no invented numbers', async () => {
        world();
        await load();
        const { container } = render(OverviewPage);
        await screen.findByRole('group', { name: 'Totals' });
        expect(screen.queryByText('Not available yet')).toBeNull();
        expect(container).not.toHaveTextContent(/Spend today|Turns, last 24/);
        expect(container).toHaveTextContent('Costs and traces come with the observability adapter');
    });
    it('says so when nothing needs attention', async () => {
        world({ agents: [agent()] });
        await load();
        render(OverviewPage);
        expect(await screen.findByText('Every agent is Ready.')).toBeInTheDocument();
    });
    it('warns when the operator stop switch is on', async () => {
        const p = platform();
        world({ platform: { policy: { ...p.policy, suspendAll: true } } });
        await load();
        render(OverviewPage);
        expect(await screen.findByText(/stop switch/)).toBeInTheDocument();
    });
    it('has no accessibility violations', async () => {
        world();
        await load();
        const { container } = render(OverviewPage);
        await screen.findByRole('group', { name: 'Totals' });
        const r = await axe.run(container, {
            rules: { 'color-contrast': { enabled: false }, region: { enabled: false } },
        });
        expect(r.violations.map((v) => v.id)).toEqual([]);
    });
});

describe('Models', () => {
    it('lists the catalog models with policy and the agents that use them', async () => {
        world();
        await load();
        render(ModelsPage);
        const haiku = await screen.findByRole('button', { name: /claude-haiku/ });
        expect(haiku).toHaveTextContent('Allowed');
        await waitFor(() => expect(haiku).toHaveTextContent('4 agents'));
        const sonnet = screen.getByRole('button', { name: /claude-sonnet/ });
        expect(sonnet).toHaveTextContent('Not allowed');
        expect(screen.getAllByText('http://gw/v1').length).toBeGreaterThan(0);
        expect(screen.getByRole('status')).toHaveTextContent('gateway.models');
        await userEvent.click(sonnet);
        const detail = screen.getByRole('complementary');
        expect(detail).toHaveTextContent('assistant');
        expect(detail).toHaveTextContent('not in the policy');
    });
});

describe('Tools', () => {
    it('shows profiles as cards and the detail with the tool list', async () => {
        world();
        await load();
        render(ToolsPage);
        const lookup = await screen.findByRole('button', { name: /lookup/ });
        expect(lookup).toHaveTextContent('code mode');
        expect(lookup).toHaveTextContent('Allowed');
        expect(screen.getByRole('button', { name: /browse/ })).toHaveTextContent('Not allowed');
        await userEvent.click(lookup);
        const detail = screen.getByRole('complementary');
        expect(detail).toHaveTextContent('toolhive-vmcp-lookup');
        expect(detail).toHaveTextContent('osv_query_vulnerability');
        expect(detail).toHaveTextContent('researcher');
        expect(document.body).not.toHaveTextContent(/calls/i);
    });
});

describe('Skills', () => {
    it('shows the shortened digest, copies the full reference, and who uses it', async () => {
        world();
        await load();
        render(SkillsPage);
        const card = await screen.findByRole('button', { name: /openagentix-canary/ });
        expect(card).toHaveTextContent('sha256:9c1e…b07d');
        expect(card).toHaveTextContent('Allowed');
        await waitFor(() => expect(card).toHaveTextContent('1 agent'));
        expect(screen.getByRole('button', { name: /openagentix-triage/ })).toHaveTextContent('Not allowed');
        await userEvent.click(card);
        const detail = screen.getByRole('complementary');
        expect(detail).toHaveTextContent(FULL);
        expect(within(detail).getByRole('button', { name: /Copy/ })).toBeInTheDocument();
    });
});

describe('Memory', () => {
    it('shows availability, the limits and which agents remember', async () => {
        world();
        await load();
        render(MemoryPage);
        const rows = await screen.findByRole('region', { name: 'Agents that remember' });
        await waitFor(() => expect(rows).toHaveTextContent('researcher'));
        expect(rows).toHaveTextContent('20 days');
        expect(rows).toHaveTextContent('assistant');
        expect(rows).toHaveTextContent('Chart');
        expect(screen.getByText('15 days by default, at most 30 days')).toBeInTheDocument();
        expect(document.body).toHaveTextContent('The console has no source for the counts');
        expect(document.body).toHaveTextContent("A person's memories are never listed");
    });
});

describe('Governance', () => {
    it('shows the policy, the always-enforced list, and a YAML view', async () => {
        world();
        await load();
        render(GovernancePage);
        const pol = await screen.findByRole('region', { name: 'What a definition may use' });
        expect(pol).toHaveTextContent('at most 5 definitions');
        expect(pol).toHaveTextContent('https://api.osv.dev');
        expect(screen.getByRole('region', { name: 'Always enforced' })).toBeInTheDocument();
        await userEvent.click(screen.getByRole('tab', { name: 'YAML' }));
        expect(screen.getByLabelText('Platform policy YAML')).toHaveTextContent('maxAgents: 5');
    });
    it('lists effective egress and tools per agent, and is honest about gate callers', async () => {
        world();
        await load();
        render(GovernancePage);
        await userEvent.click(await screen.findByRole('tab', { name: 'Egress and tools' }));
        const row = screen.getByRole('row', { name: /researcher/ });
        expect(row).toHaveTextContent('https://api.osv.dev');
        expect(row).toHaveTextContent('osv_query_vulnerability');
        expect(screen.getByRole('row', { name: /assistant/ })).toHaveTextContent('not read for chart agents');
        await userEvent.click(screen.getByRole('tab', { name: 'Gate callers' }));
        expect(screen.getByText(/no source in the console API/)).toBeInTheDocument();
        expect(screen.queryByRole('table')).toBeNull();
    });
});
