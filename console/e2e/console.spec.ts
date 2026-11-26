import { expect, test, type Page } from '@playwright/test';

const TOKEN = 'demo-token';
const SENTENCES = [
    'the definition lists tool "knowledge_kb_get_document" which is not in profile "lookup" (the profile offers: knowledge_kb_search, osv_query_vulnerability, osv_get_vulnerability, execute_tool_script)',
    'egress.allow entry "https://services.nvd.nist.gov" is not matched by the platform policy',
];

/** Collects what the strict Content-Security-Policy would complain about, and browser errors. */
async function watch(page: Page, allow: RegExp[] = []) {
    const problems: string[] = [];
    await page.addInitScript(() => {
        (window as unknown as { __csp: string[] }).__csp = [];
        document.addEventListener('securitypolicyviolation', (e) => {
            (window as unknown as { __csp: string[] }).__csp.push(
                `${e.violatedDirective} ${e.blockedURI} ${e.sample ?? ''}`,
            );
        });
    });
    page.on('console', (m) => {
        if (m.type() === 'error' && !allow.some((r) => r.test(m.text()))) problems.push(`console: ${m.text()}`);
    });
    page.on('pageerror', (e) => problems.push(`pageerror: ${e.message}`));
    return async () => {
        const csp = await page.evaluate(() => (window as unknown as { __csp: string[] }).__csp);
        expect(csp, 'securitypolicyviolation events').toEqual([]);
        expect(problems, 'console errors').toEqual([]);
    };
}

async function signIn(page: Page, token = TOKEN) {
    await page.goto('/');
    await page.getByLabel('Console token').fill(token);
    await page.getByRole('button', { name: 'Sign in' }).click();
}

async function goTo(page: Page, href: string) {
    const menu = page.getByRole('button', { name: 'Open navigation' });
    if (await menu.isVisible()) await menu.click();
    await page.locator(`nav[aria-label="Main"] a[href="${href}"]`).first().click();
}

test('the app shell shows no data before sign-in, and a wrong token is refused', async ({ page }) => {
    const done = await watch(page, [/status of 401/]); // the refusal itself is logged by the browser
    await page.goto('/');
    await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
    await expect(page.locator('body')).not.toContainText('researcher');
    await page.getByLabel('Console token').fill('wrong');
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page.getByRole('alert')).toContainText('The console token was not accepted');
    await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
    expect(await page.evaluate(() => JSON.stringify(localStorage))).not.toContain('wrong');
    await done();
});

test('sign in, see the registry with the demo data, and the token is never stored', async ({ page }) => {
    const done = await watch(page);
    await signIn(page);
    await expect(page.getByText('Demo data')).toBeVisible();
    await goTo(page, '/agents');
    const rows = page.locator('#agentTable tbody tr');
    await expect(rows).toHaveCount(5);
    await expect(page.locator('tr[data-agent="researcher"]')).toContainText('Ready');
    await expect(page.locator('tr[data-agent="release-notes"]')).toContainText('Pending');
    await expect(page.locator('tr[data-agent="cve-triage"]')).toContainText('Refused');
    await expect(page.locator('tr[data-agent="assistant"]')).toContainText('Chart');
    await expect(page.getByTestId('used')).toContainText('3 of 5 definitions used');
    expect(
        await page.evaluate(() => JSON.stringify(localStorage) + JSON.stringify(sessionStorage) + document.cookie),
    ).not.toContain(TOKEN);
    await page.getByLabel('Filter agents by name').fill('cve');
    await expect(rows).toHaveCount(1);
    await page
        .getByRole('button', { name: 'Settings' })
        .or(page.getByRole('link', { name: 'Settings' }))
        .first()
        .click();
    await page.getByRole('button', { name: 'Sign out' }).click();
    await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
    await done();
});

test('the pages with no data source say so, and show nothing invented', async ({ page }) => {
    const done = await watch(page);
    await signIn(page);
    for (const [href, title] of [
        ['/knowledge', 'Knowledge'],
        ['/channels', 'Channels and triggers'],
    ]) {
        await goTo(page, href!);
        await expect(page.getByRole('heading', { level: 1, name: title })).toBeVisible();
        await expect(page.getByText('Why it is not available yet')).toBeVisible();
    }
    await done();
});

test('Schedules and Access show the demo data read-only, with a detail view, and never a user id', async ({ page }) => {
    const done = await watch(page);
    await signIn(page);
    await goTo(page, '/schedules');
    await expect(page.getByRole('heading', { level: 1, name: 'Schedules' })).toBeVisible();
    await expect(page.getByText('Read-only in this release').first()).toBeVisible();
    const sched = page.getByRole('region', { name: 'Schedules defined in chart values' });
    await expect(sched.getByRole('row', { name: /daily-digest/ })).toContainText('on weekdays at 07:00');
    await expect(sched.getByRole('row', { name: /weekly-review/ })).toContainText('Suspended');
    await sched.getByRole('button', { name: 'daily-digest' }).click();
    await expect(page.getByRole('dialog')).toContainText('Forbid');
    await page.getByRole('button', { name: 'Close' }).click();
    await expect(page.getByRole('dialog')).toHaveCount(0);

    await goTo(page, '/access');
    await expect(page.getByRole('heading', { level: 1, name: 'Access' })).toBeVisible();
    const acc = page.getByRole('region', { name: 'Who may call which agent' });
    await expect(acc.getByRole('row', { name: /ci-checker/ })).toContainText('kagent/researcher');
    await expect(acc.getByRole('row', { name: /bridge/ })).toContainText('any user id with a fixed start');
    await expect(page.locator('body')).not.toContainText('telegram:');
    await acc.getByRole('button', { name: 'ci-checker' }).click();
    await expect(page.getByRole('dialog')).toContainText('ci/checker');
    await done();
});

test('Overview shows real tiles and what needs attention', async ({ page }) => {
    const done = await watch(page);
    await signIn(page);
    await expect(page.getByRole('heading', { level: 1, name: 'Overview' })).toBeVisible();
    await expect(page.getByText('Not available yet')).toHaveCount(0);
    const tiles = page.getByRole('group', { name: 'Totals' });
    await expect(tiles).toContainText('1 pending');
    await expect(tiles).toContainText('1 refused');
    await expect(tiles).toContainText('2 chart-managed');
    await expect(tiles.locator('.tile', { hasText: 'Definitions used' })).toContainText('3of 5');
    const att = page.getByRole('region', { name: 'Needs attention' });
    await expect(att.getByRole('link', { name: 'cve-triage' })).toBeVisible();
    await expect(att).toContainText('which is not in profile "lookup"');
    await expect(att.getByRole('link', { name: 'release-notes' })).toBeVisible();
    await expect(page.getByRole('region', { name: /Platform health/ })).toContainText('A2A gate');
    await expect(page.getByRole('region', { name: 'Security posture' })).toBeVisible();
    // demo mode serves fixed, invented metrics (the page says "Demo data"): the metrics row and the per-agent spend show
    const metrics = page.getByRole('group', { name: /Metrics/ });
    await expect(metrics).toContainText('Spend today');
    await expect(metrics.getByRole('img', { name: /Spend per step/ })).toBeVisible();
    await expect(page.getByRole('list', { name: 'Spend per agent key' })).toContainText('assistant');
    await page.getByRole('link', { name: /Open Governance/ }).click();
    await expect(page.getByRole('heading', { level: 1, name: 'Governance' })).toBeVisible();
    await done();
});

test('Tools: choose a profile and read its tools and who uses it', async ({ page }) => {
    const done = await watch(page);
    await signIn(page);
    await goTo(page, '/tools');
    await expect(page.getByRole('heading', { level: 1, name: 'Tools' })).toBeVisible();
    await expect(page.getByRole('button', { name: /browse/ })).toContainText('Not allowed');
    await page.getByRole('button', { name: /lookup/ }).click();
    const detail = page.getByRole('complementary');
    await expect(detail).toContainText('toolhive-vmcp-lookup');
    await expect(detail).toContainText('osv_query_vulnerability');
    await expect(detail).toContainText('researcher');
    await done();
});

test('Models, Skills and Memory show catalog data, and Governance shows the policy as YAML', async ({ page }) => {
    const done = await watch(page);
    await signIn(page);
    await goTo(page, '/models');
    await expect(page.getByRole('button', { name: /claude-sonnet/ })).toContainText('Not allowed');
    await goTo(page, '/skills');
    await expect(page.getByRole('button', { name: /openagentix-canary/ })).toContainText('sha256:');
    await goTo(page, '/memory');
    await expect(page.getByRole('region', { name: 'Agents that remember' })).toContainText('assistant');
    await goTo(page, '/governance');
    await expect(page.getByRole('region', { name: 'Always enforced' })).toBeVisible();
    await page.getByRole('tab', { name: 'Egress and tools' }).click();
    await expect(page.getByRole('row', { name: /cve-triage/ })).toContainText('none (refused)');
    await page.getByRole('tab', { name: 'Gate callers' }).click();
    await expect(page.getByRole('link', { name: 'Open Access' })).toHaveAttribute('href', '/access');
    await page.getByRole('button', { name: 'View YAML' }).click();
    await expect(page.getByLabel('Platform policy YAML', { exact: true })).toContainText('maxAgents: 5');
    await expect(page.getByLabel('Platform policy YAML', { exact: true })).toContainText('registry.ci.svc:5000');
    await done();
});

test('Costs shows the metrics for a window, and the table view', async ({ page }) => {
    const done = await watch(page);
    await signIn(page);
    await goTo(page, '/costs');
    await expect(page.getByRole('heading', { level: 1, name: 'Costs' })).toBeVisible();
    const totals = page.getByRole('group', { name: 'Totals' });
    await expect(totals).toContainText('Spend, last 24h');
    await expect(totals).toContainText('$0.191');
    await page.getByRole('radio', { name: 'Last 7 d' }).click();
    await expect(totals).toContainText('Spend, last 7d');
    await expect(totals).toContainText('$1.22');
    await expect(page.getByRole('row', { name: /assistant/ })).toContainText('$');
    await done();
});

test('Traces: recent turns and a waterfall with a span detail, no content', async ({ page }) => {
    const done = await watch(page);
    await signIn(page);
    await goTo(page, '/traces');
    await expect(page.getByRole('heading', { level: 1, name: 'Traces' })).toBeVisible();
    const row = page.locator('tr[data-trace]').first();
    await expect(row).toContainText('researcher');
    await expect(row).toContainText('Completed');
    await row.getByRole('button', { name: /Open trace/ }).click();
    const wf = page.getByRole('list', { name: /Spans of the turn/ });
    await expect(wf.getByRole('button')).toHaveCount(4);
    await wf.getByRole('button', { name: /execute_tool osv_query_vulnerability/ }).click();
    await expect(page.getByRole('complementary')).toContainText('gen_ai.tool.name');
    await expect(page.getByRole('complementary')).not.toContainText(/gen_ai\.prompt|arguments/);
    await done();
});

test('the sidebar context line is fully visible and clear of the first item', async ({ page }) => {
    for (const size of [
        { width: 1440, height: 900 },
        { width: 1440, height: 420 }, // a short window: the sidebar scrolls, the line must not shrink
    ]) {
        await page.setViewportSize(size);
        await signIn(page);
        const sb = page.locator('nav[aria-label="Main"]');
        const ctxLine = sb.locator('.ctx');
        await expect(ctxLine).toHaveText('demo · kagent');
        const box = (await ctxLine.boundingBox())!;
        const sbBox = (await sb.boundingBox())!;
        const first = (await sb.locator('.ni').first().boundingBox())!;
        expect(box.height, `context line height at ${size.height}`).toBeGreaterThanOrEqual(14);
        expect(box.y).toBeGreaterThanOrEqual(sbBox.y);
        expect(box.y + box.height).toBeLessThanOrEqual(sbBox.y + sbBox.height);
        expect(box.y + box.height, 'the first nav item overlaps the context line').toBeLessThanOrEqual(first.y);
        const clipped = await ctxLine.evaluate((e) => e.scrollHeight > e.clientHeight);
        expect(clipped, 'the context line is clipped').toBe(false);
    }
});

test('a refused agent shows both violation sentences word for word', async ({ page }) => {
    const done = await watch(page);
    await signIn(page);
    await goTo(page, '/agents');
    await page.locator('tr[data-agent="cve-triage"] a').click();
    const list = page.getByTestId('violations');
    await expect(list.getByRole('listitem')).toHaveText(SENTENCES);
    await expect(page.getByText('2 rules refused this definition')).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Refused by the platform policy' })).toBeVisible();
    await done();
});

test('open researcher, edit the description, save', async ({ page }) => {
    const done = await watch(page);
    await signIn(page);
    await goTo(page, '/agents');
    await page.locator('tr[data-agent="researcher"] a').click();
    await expect(page.getByRole('heading', { level: 1, name: 'researcher' })).toBeVisible();
    await expect(page.getByText('Status is for generation 3, the current one.')).toBeVisible();
    const desc = page.getByLabel('Description');
    await desc.fill('Looks things up and cites what it found, briefly');
    await page.getByRole('button', { name: 'Save', exact: true }).click();
    await expect(page.getByRole('status').filter({ hasText: 'Saved researcher' })).toBeVisible();
    await expect(page.getByText(/Status is for generation 3; you are looking at generation 4/)).toBeVisible();
    await page.getByRole('button', { name: 'View YAML' }).click();
    await expect(page.getByRole('dialog')).toContainText('Looks things up and cites what it found, briefly');
    await page.keyboard.press('Escape');
    await expect(page.getByRole('dialog')).toHaveCount(0);
    await done();
});

test('create a new agent and see it Pending', async ({ page }) => {
    const done = await watch(page);
    await signIn(page);
    await goTo(page, '/agents');
    await page.getByRole('button', { name: /New agent/ }).click();
    await page.getByLabel('Name', { exact: true }).fill('e2e-agent');
    await page.getByLabel('Description').fill('Made by the end-to-end test');
    await page.getByLabel('Instructions').fill('Answer in one sentence.');
    await page.getByRole('button', { name: 'Create agent' }).click();
    await expect(page.getByRole('heading', { level: 1, name: 'e2e-agent' })).toBeVisible();
    await expect(page.locator('.ph .badge')).toHaveText('Pending');
    await goTo(page, '/agents');
    await expect(page.locator('tr[data-agent="e2e-agent"]')).toContainText('Pending');
    await expect(page.getByTestId('used')).toContainText('4 of 5');
    await done();
});

test('with a required tool profile and none available, the builder says so and cannot create', async ({ page }) => {
    const done = await watch(page);
    await page.route('**/api/v1/platform', async (route) => {
        const res = await route.fetch();
        const body = await res.json();
        await route.fulfill({ response: res, json: { ...body, profiles: [] } });
    });
    await signIn(page);
    await goTo(page, '/agents');
    await page.getByRole('button', { name: /New agent/ }).click();
    await expect(page.getByTestId('no-profile')).toContainText(
        'This platform requires a tool profile and none is available',
    );
    await expect(page.getByTestId('no-profile')).toContainText('mcp.profiles');
    await page.getByLabel('Name', { exact: true }).fill('no-profile-agent');
    await page.getByLabel('Instructions').fill('Answer in one sentence.');
    await expect(page.getByRole('button', { name: 'Create agent' })).toHaveAttribute('aria-disabled', 'true');
    await done();
});

test('a draft that the policy would refuse is flagged before saving', async ({ page }) => {
    const done = await watch(page);
    await signIn(page);
    await goTo(page, '/agents');
    await page.locator('tr[data-agent="researcher"] a').click();
    await page.getByPlaceholder('https://host[:port]').fill('https://services.nvd.nist.gov');
    await page.getByRole('button', { name: 'Add' }).click();
    await expect(page.getByText('This draft would be refused')).toBeVisible();
    await expect(page.getByTestId('predicted')).toContainText('is not matched by the platform policy');
    await expect(page.getByRole('button', { name: 'Save anyway' })).toBeVisible();
    await done();
});

test('delete asks for the name, then removes the agent', async ({ page }) => {
    const done = await watch(page);
    await signIn(page);
    await goTo(page, '/agents');
    await page.locator('tr[data-agent="e2e-agent"] a').click();
    await page.getByRole('button', { name: 'Delete', exact: true }).click();
    const dlg = page.getByRole('alertdialog');
    await expect(dlg.getByRole('button', { name: 'Cancel' })).toBeFocused();
    const go = dlg.getByRole('button', { name: 'Delete agent' });
    await expect(go).toHaveAttribute('aria-disabled', 'true');
    await dlg.getByLabel('Type e2e-agent to confirm').fill('e2e-agent');
    await go.click();
    await expect(page.getByRole('heading', { level: 1, name: 'Agents' })).toBeVisible();
    await expect(page.locator('tr[data-agent="e2e-agent"]')).toHaveCount(0);
    await done();
});

test('bring your own agent: the digest rule is explained, then a container agent is created', async ({ page }) => {
    const done = await watch(page);
    await signIn(page);
    await goTo(page, '/agents');
    await page.getByRole('button', { name: /New agent/ }).click();
    await page.getByRole('link', { name: 'Bring your own agent' }).click();
    await expect(page.getByRole('heading', { level: 1, name: 'Bring your own agent' })).toBeVisible();
    await expect(page.getByLabel('Instructions')).toHaveCount(0);
    const create = page.getByRole('button', { name: 'Create agent' });
    await page.getByLabel('Name', { exact: true }).fill('byo-agent');
    // a tag is explained in plain English and keeps Create off
    await page.getByLabel('Image').fill('registry.example.com/agents/echo:latest');
    await expect(page.locator('.err')).toContainText('The image must be pinned by digest');
    await expect(create).toHaveAttribute('aria-disabled', 'true');
    // an image of another registry names the allowed one
    await page.getByLabel('Image').fill('evil.example.com/x@sha256:' + 'c'.repeat(64));
    await expect(page.locator('.err')).toContainText('registry.example.com/agents/');
    // a secret-shaped value is refused and not echoed
    await page.getByRole('button', { name: 'Add variable' }).click();
    await page.getByLabel('Variable 1 name').fill('TOKEN');
    await page.getByLabel('Variable 1 value').fill('sk-' + 'a'.repeat(40));
    await expect(page.getByRole('alert').filter({ hasText: 'shaped like a secret' })).toBeVisible();
    await page.getByRole('button', { name: 'Remove variable 1' }).click();
    // a good image passes the platform check, and only then can the agent be created
    await page.getByLabel('Image').fill('registry.example.com/agents/echo@sha256:' + 'c'.repeat(64));
    await expect(create).not.toHaveAttribute('aria-disabled', 'true');
    await create.click();
    await expect(page.getByRole('heading', { level: 1, name: 'byo-agent' })).toBeVisible();
    await expect(page.getByText('This is a container agent')).toBeVisible();
    await expect(page.getByTestId('container-note')).toContainText('registry.example.com/agents/echo@sha256:');
    await expect(page.getByRole('button', { name: 'Save' })).toHaveCount(0);
    await goTo(page, '/agents');
    await expect(page.locator('tr[data-agent="byo-agent"]')).toContainText('container');
    await done();
});

test('pause and resume an agent', async ({ page }) => {
    const done = await watch(page);
    await signIn(page);
    await goTo(page, '/agents');
    await page.locator('tr[data-agent="researcher"] a').click();
    await page.getByRole('button', { name: 'Pause', exact: true }).click();
    await expect(page.locator('.ph .badge')).toHaveText('Paused');
    await goTo(page, '/agents');
    await expect(page.locator('tr[data-agent="researcher"]')).toContainText('Paused');
    await page.locator('tr[data-agent="researcher"] a').click();
    await page.getByRole('button', { name: 'Resume', exact: true }).click();
    await expect(page.locator('.ph .badge')).toHaveText('Ready');
    await done();
});

test('chart agents open read-only', async ({ page }) => {
    const done = await watch(page);
    await signIn(page);
    await goTo(page, '/agents');
    await page.locator('tr[data-agent="assistant"] a').click();
    await expect(page.getByText(/This agent comes from chart values/)).toBeVisible();
    await expect(page.getByRole('button', { name: 'Save' })).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Delete', exact: true })).toHaveCount(0);
    await done();
});

test('the create flow works with the keyboard alone', async ({ page }) => {
    const done = await watch(page);
    await signIn(page);
    await goTo(page, '/agents');
    // `n` is the shortcut for a new agent
    await page.locator('body').click({ position: { x: 5, y: 5 } });
    await page.keyboard.press('n');
    await expect(page.getByRole('heading', { level: 1, name: 'New agent' })).toBeVisible();
    await page.getByLabel('Name', { exact: true }).focus();
    await page.keyboard.type('kb-agent');
    await page.keyboard.press('Tab'); // namespace is read only, so the next stop is the description
    await page.keyboard.press('Tab');
    await page.keyboard.type('Keyboard only');
    await page.keyboard.press('Tab');
    await page.keyboard.type('Say hello.');
    // Ctrl+S saves
    await page.keyboard.press('Control+s');
    await expect(page.getByRole('heading', { level: 1, name: 'kb-agent' })).toBeVisible();
    // tabs move with the arrow keys
    await page.getByRole('tab', { name: 'Build' }).focus();
    await page.keyboard.press('ArrowRight');
    await page.keyboard.press('ArrowRight');
    await expect(page.getByRole('tab', { name: 'Deploy' })).toHaveAttribute('aria-selected', 'true');
    await expect(page.getByText('Caller rule to hand to an operator')).toBeVisible();
    await done();
});

test('the theme toggle persists', async ({ page }) => {
    const done = await watch(page);
    await signIn(page);
    const html = page.locator('html');
    const before = await html.evaluate((e) => e.classList.contains('dark'));
    await page.locator('#theme-toggle').click();
    await expect(html).toHaveClass(before ? /^((?!dark).)*$/ : /dark/);
    const stored = await page.evaluate(() => localStorage.getItem('oa-theme'));
    expect(stored).toBe(before ? 'light' : 'dark');
    await page.reload();
    expect(await html.evaluate((e) => e.classList.contains('dark'))).toBe(!before);
    await done();
});

test.describe('390 px wide', () => {
    test.use({ viewport: { width: 390, height: 844 } });
    test('no page scrolls sideways, and the drawer works', async ({ page }) => {
        const done = await watch(page);
        await signIn(page);
        const noScroll = async (what: string) => {
            const w = await page.evaluate(() => ({
                sw: document.documentElement.scrollWidth,
                cw: document.documentElement.clientWidth,
            }));
            expect(w.sw, `${what} scrolls sideways`).toBeLessThanOrEqual(w.cw);
        };
        await noScroll('overview');
        await page.getByRole('button', { name: 'Open navigation' }).click();
        await expect(page.locator('nav[aria-label="Main"]')).toBeInViewport();
        await page.keyboard.press('Escape');
        await goTo(page, '/agents');
        await expect(page.locator('#agentTable')).toBeVisible();
        await noScroll('registry');
        await page.locator('tr[data-agent="researcher"] a').click();
        await expect(page.getByText('Status is for generation')).toBeVisible();
        await noScroll('builder');
        await page.getByRole('tab', { name: 'Deploy' }).click();
        await noScroll('deploy');
        await goTo(page, '/models');
        await noScroll('models');
        await goTo(page, '/governance');
        await noScroll('governance');
        await goTo(page, '/');
        await noScroll('overview with data');
        await done();
    });
});

test('the token field hides the token and can show it', async ({ page }) => {
    await page.goto('/');
    const field = page.getByLabel('Console token');
    await expect(field).toHaveAttribute('type', 'password');
    await page.getByRole('button', { name: 'Show token' }).click();
    await expect(field).toHaveAttribute('type', 'text');
    await page.getByRole('button', { name: 'Hide token' }).click();
    await expect(field).toHaveAttribute('type', 'password');
});

test('a request with a foreign Host is refused before anything else (DNS rebinding)', async ({ request }) => {
    const rebound = await request.get('/api/v1/session', {
        headers: { Host: 'rebound.example', Authorization: `Bearer ${TOKEN}` },
    });
    expect(rebound.status()).toBe(421);
    expect(await rebound.text()).toBe('');
    const own = await request.get('/api/v1/session', { headers: { Authorization: `Bearer ${TOKEN}` } });
    expect(own.status()).toBe(200);
    expect(own.headers()['cross-origin-resource-policy']).toBe('same-origin');
});
