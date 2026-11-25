import { render, screen, waitFor, within } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';
import axe from 'axe-core';
import { beforeEach, describe, expect, it } from 'vitest';
import { setTransport } from '$lib/api';
import { auth } from '$lib/auth.svelte';
import type { AccessList, ScheduleList } from '$lib/types';
import AccessPage from './AccessPage.svelte';
import SchedulesPage from './SchedulesPage.svelte';

const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

const SCHEDULES: ScheduleList = {
    configured: true,
    namespace: 'openagentix-schedules',
    items: [
        {
            name: 'daily-digest',
            agent: 'assistant',
            cron: '0 7 * * 1-5',
            timeZone: 'Europe/Berlin',
            concurrencyPolicy: 'Forbid',
            timeout: '5m',
            state: 'active',
            active: 0,
            lastScheduled: '2026-11-26T06:00:00Z',
            lastSucceeded: '2026-11-26T06:00:09Z',
            created: '2026-11-20T08:00:00Z',
        },
        {
            name: 'weekly-review',
            agent: '',
            cron: '0 9 1 * *',
            timeZone: '',
            concurrencyPolicy: 'Allow',
            timeout: '',
            state: 'suspended',
            active: 1,
            lastScheduled: '',
            lastSucceeded: '',
            created: '2026-11-20T08:00:00Z',
        },
    ],
};

const ACCESS: AccessList = {
    configured: true,
    namespace: 'openagentix-governance',
    items: [
        {
            name: 'bridge',
            source: 'chart',
            serviceAccount: 'openagentix-bridge/telegram-bridge',
            key: false,
            agents: ['kagent/assistant'],
            userIdRule: 'prefix',
            methods: ['SendMessage'],
            memory: true,
        },
        {
            name: 'kourier-hook',
            source: 'chart',
            serviceAccount: '',
            key: true,
            agents: ['kagent/assistant', 'kagent/researcher'],
            userIdRule: 'fixed',
            methods: ['SendMessage', 'SendStreamingMessage'],
            memory: false,
        },
        {
            name: 'ci',
            source: 'values',
            serviceAccount: 'ci/checker',
            key: false,
            agents: ['kagent/researcher'],
            userIdRule: 'exact',
            methods: ['SendMessage', 'GetTask', 'CancelTask'],
            memory: false,
        },
    ],
};

function serve(routes: Record<string, () => Response>) {
    setTransport(async (url) => routes[url]?.() ?? new Response('{}', { status: 404 }));
}

beforeEach(() => auth.signIn('tok'));

describe('Schedules', () => {
    it('lists each schedule with its agent, cron in words, state and last run', async () => {
        serve({ '/api/v1/schedules': () => json(SCHEDULES) });
        render(SchedulesPage);
        const rows = await screen.findByRole('region', { name: 'Schedules defined in chart values' });
        const d = within(rows).getByRole('row', { name: /daily-digest/ });
        expect(d).toHaveTextContent('assistant');
        expect(d).toHaveTextContent('on weekdays at 07:00');
        expect(d).toHaveTextContent('Europe/Berlin');
        expect(d).toHaveTextContent('Active');
        const w = within(rows).getByRole('row', { name: /weekly-review/ });
        expect(w).toHaveTextContent('0 9 1 * *');
        expect(w).toHaveTextContent('Suspended');
        expect(w).toHaveTextContent('Never');
        expect(document.body).toHaveTextContent('Read-only in this release');
    });
    it('opens a detail view for one schedule and closes it', async () => {
        serve({ '/api/v1/schedules': () => json(SCHEDULES) });
        render(SchedulesPage);
        await userEvent.click(await screen.findByRole('button', { name: 'daily-digest' }));
        const dlg = screen.getByRole('dialog');
        expect(dlg).toHaveTextContent('Forbid');
        expect(dlg).toHaveTextContent('5m');
        expect(dlg).toHaveTextContent('0 7 * * 1-5');
        expect(dlg).toHaveTextContent('openagentix-schedules');
        expect(dlg).not.toHaveTextContent('schedule:daily-digest');
        await userEvent.click(within(dlg).getByRole('button', { name: 'Close' }));
        await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    });
    it('says in plain words when no schedule is defined', async () => {
        serve({ '/api/v1/schedules': () => json({ configured: false, namespace: '', items: [] }) });
        render(SchedulesPage);
        expect(await screen.findByRole('heading', { name: 'No schedules are defined' })).toBeInTheDocument();
        expect(document.body).toHaveTextContent('Add them under `schedules`'.replaceAll('`', ''));
        expect(screen.queryByRole('table')).toBeNull();
    });
    it('says the namespace has none when it is configured but empty', async () => {
        serve({ '/api/v1/schedules': () => json({ configured: true, namespace: 'openagentix-schedules', items: [] }) });
        render(SchedulesPage);
        expect(await screen.findByRole('heading', { name: 'No schedules are defined' })).toBeInTheDocument();
        expect(document.body).toHaveTextContent('openagentix-schedules');
    });
    it('shows the error in plain words and no table', async () => {
        serve({
            '/api/v1/schedules': () =>
                json({ error: { code: 'cluster_error', message: 'Could not read the schedules.' } }, 502),
        });
        render(SchedulesPage);
        const alert = await screen.findByRole('alert');
        expect(alert).toHaveTextContent('Could not read the schedules');
        expect(screen.queryByRole('table')).toBeNull();
    });
    it('has no accessibility violations', async () => {
        serve({ '/api/v1/schedules': () => json(SCHEDULES) });
        const { container } = render(SchedulesPage);
        await screen.findByRole('table');
        const r = await axe.run(container, { rules: { 'color-contrast': { enabled: false } } });
        expect(r.violations.map((v) => v.id)).toEqual([]);
    });
});

describe('Access rules', () => {
    it('lists each caller with its agents, methods and the kind of user id rule', async () => {
        serve({ '/api/v1/access': () => json(ACCESS) });
        render(AccessPage);
        const rows = await screen.findByRole('region', { name: 'Who may call which agent' });
        const b = within(rows).getByRole('row', { name: /bridge/ });
        expect(b).toHaveTextContent('kagent/assistant');
        expect(b).toHaveTextContent('send only');
        expect(b).toHaveTextContent('any user id with a fixed start');
        expect(b).toHaveTextContent('Chart');
        const k = within(rows).getByRole('row', { name: /kourier-hook/ });
        expect(k).toHaveTextContent('kagent/researcher');
        expect(k).toHaveTextContent('send and stream');
        expect(k).toHaveTextContent('Key');
        const c = within(rows).getByRole('row', { name: /^ci/ });
        expect(c).toHaveTextContent('Values');
        expect(c).toHaveTextContent('3 methods');
        expect(document.body).toHaveTextContent('Keys, key hashes and user ids are never shown');
    });
    it('opens a detail view with the service account and all methods', async () => {
        serve({ '/api/v1/access': () => json(ACCESS) });
        render(AccessPage);
        await userEvent.click(await screen.findByRole('button', { name: 'ci' }));
        const dlg = screen.getByRole('dialog');
        expect(dlg).toHaveTextContent('ci/checker');
        expect(dlg).toHaveTextContent('GetTask');
        expect(dlg).toHaveTextContent('CancelTask');
        expect(dlg).toHaveTextContent('one exact user id');
    });
    it('says in plain words that the gate is off', async () => {
        serve({ '/api/v1/access': () => json({ configured: false, namespace: '', items: [] }) });
        render(AccessPage);
        expect(await screen.findByRole('heading', { name: 'The gate is off' })).toBeInTheDocument();
        expect(document.body).toHaveTextContent('governance.a2a.enabled');
        expect(screen.queryByRole('table')).toBeNull();
    });
    it('says when the rules file is missing', async () => {
        serve({
            '/api/v1/access': () =>
                json({ error: { code: 'gate_rules_missing', message: 'The gate rules are not there.' } }, 404),
        });
        render(AccessPage);
        const alert = await screen.findByRole('alert');
        expect(alert).toHaveTextContent('The gate rules are not there');
    });
    it('has no accessibility violations', async () => {
        serve({ '/api/v1/access': () => json(ACCESS) });
        const { container } = render(AccessPage);
        await screen.findByRole('table');
        const r = await axe.run(container, { rules: { 'color-contrast': { enabled: false } } });
        expect(r.violations.map((v) => v.id)).toEqual([]);
    });
});
