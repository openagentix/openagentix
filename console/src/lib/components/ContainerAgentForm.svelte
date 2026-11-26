<script lang="ts">
    import { goto } from '$app/navigation';
    import { api, ApiError, describeError } from '$lib/api';
    import {
        containerAvailability,
        containerProblems,
        containerProfileOptions,
        containerSpec,
        emptyContainerDraft,
        imageExample,
        MAX_ENV_VARS,
        MAX_PORT,
        MIN_PORT,
        type ContainerDraft,
        type ContainerField,
    } from '$lib/container';
    import { ctx } from '$lib/context.svelte';
    import { MAX_DESCRIPTION, MAX_NAME, counterText, modelOptions } from '$lib/draft';
    import { toasts } from '$lib/toast.svelte';
    import type { Prediction, ValidateResult } from '$lib/types';
    import Button from './Button.svelte';
    import Notice from './Notice.svelte';
    import PageHeader from './PageHeader.svelte';
    import SelectField from './SelectField.svelte';
    import Skeleton from './Skeleton.svelte';
    import TextField from './TextField.svelte';

    const platform = $derived(ctx.platform);
    const session = $derived(ctx.session);
    const readOnly = $derived(!!session && !session.canWrite);

    let draft = $state<ContainerDraft>(emptyContainerDraft(ctx.platform ?? undefined));
    // a field shows its problem once the person has touched it; the Create button always says what is missing
    let touched = $state<Record<string, boolean>>({});
    let busy = $state(false);
    let saveError = $state('');
    let checked = $state<{ key: string; result: ValidateResult } | null>(null);
    let checkFailed = $state('');

    $effect(() => {
        if (platform && draft.model === '' && !touched.model) draft = emptyContainerDraft(platform);
    });

    const availability = $derived(platform ? containerAvailability(platform) : null);
    const problems = $derived(platform ? containerProblems(draft, platform) : {});
    const shown = (f: ContainerField): string => (touched[f] ? (problems[f] ?? '') : '');
    const touch = (f: ContainerField) => () => (touched[f] = true);
    const spec = $derived(containerSpec(draft));
    const key = $derived(JSON.stringify([draft.name, spec]));
    const example = $derived(platform ? imageExample(platform) : '');

    const firstProblem = $derived.by(() => {
        if (!draft.name) return 'Give the agent a name first.';
        for (const f of ['name', 'image', 'port', 'env', 'model', 'toolProfile'] as ContainerField[]) {
            if (problems[f]) return problems[f];
        }
        return '';
    });
    const checkable = $derived(!!platform && !readOnly && availability?.ok === true && firstProblem === '');

    // The platform's own check (the validate route) runs for the draft as it is. Nothing is created without it passing.
    $effect(() => {
        const k = key;
        const body = spec;
        const n = draft.name;
        if (!checkable) {
            checked = null;
            return undefined;
        }
        if (checked?.key === k) return undefined;
        checkFailed = '';
        const ctl = new AbortController();
        const timer = setTimeout(async () => {
            try {
                const r = await api.validate(n, body, ctl.signal);
                checked = { key: k, result: r };
            } catch (e) {
                if (ctl.signal.aborted) return;
                checked = null;
                checkFailed = describeError('check', n, e);
            }
        }, 500);
        return () => {
            clearTimeout(timer);
            ctl.abort();
        };
    });

    const result = $derived(checked && checked.key === key ? checked.result : null);
    const predicted = $derived<Prediction[]>(result?.predicted ?? []);
    const schemaErrors = $derived(result && !result.schema.ok ? result.schema.errors : []);
    const verified = $derived(!!result && predicted.length === 0 && result.schema.ok);

    const blockReason = $derived.by(() => {
        if (firstProblem) return firstProblem;
        if (checkFailed) return 'The check with the platform failed. Change something to try again.';
        if (!result) return 'Checking with the platform…';
        if (predicted.length || schemaErrors.length)
            return 'The platform would refuse this agent. Fix what is listed above first.';
        return undefined;
    });

    async function create() {
        if (busy || readOnly || !verified || !platform) return;
        busy = true;
        saveError = '';
        try {
            const d = await api.create({ name: draft.name, spec });
            toasts.success(`Created ${d.name}. Waiting for the controller.`);
            await goto(`/agents/${encodeURIComponent(d.name)}`, { replaceState: true });
        } catch (e) {
            if (!(e instanceof ApiError && e.status === 401)) {
                saveError = describeError('create', draft.name, e);
                toasts.error(saveError);
            }
        } finally {
            busy = false;
        }
    }

    function addVar() {
        draft.env = [...draft.env, { name: '', value: '' }];
    }
    function removeVar(i: number) {
        draft.env = draft.env.filter((_, j) => j !== i);
    }
</script>

<svelte:head><title>Bring your own agent · Agents · OpenAgentix console</title></svelte:head>

<section class="view max-form" data-testid="container-form">
    <PageHeader
        title="Bring your own agent"
        strip={'AgentDefinition · runtime container · namespace ' + (session?.namespace ?? '')}
    >
        {#snippet actions()}
            {#if !readOnly && availability?.ok}
                <Button
                    variant="primary"
                    {busy}
                    disabledReason={!busy ? blockReason : undefined}
                    onclick={create}
                    id="create-btn">Create agent</Button
                >
            {/if}
        {/snippet}
    </PageHeader>

    <p class="sm t2">
        Run an agent you built yourself, in any language, from a container image that speaks A2A. The platform gives it
        its own model key and budget, and sends calls to it through the A2A gate.
        <a href="/agents/new">Build an agent from instructions instead</a>.
    </p>

    {#if ctx.platformError}
        <Notice kind="error" title="The platform catalog could not be read"
            ><p class="sm">{ctx.platformError}</p></Notice
        >
    {:else if !platform}
        <div aria-busy="true">
            <span class="sr">Loading</span>
            <div class="panel">
                <div class="bd stack">
                    <Skeleton class="w-[30%]" /><Skeleton class="w-full" /><Skeleton class="w-[60%]" />
                </div>
            </div>
        </div>
    {:else if availability && !availability.ok}
        <Notice kind="ro" title="Container agents are off on this platform"
            ><p class="sm">{availability.reason}</p></Notice
        >
    {:else}
        {#if readOnly}
            <Notice kind="ro" title="This console is read-only">
                <p class="sm">
                    The console runs in viewer mode, so it shows what the form would ask for but cannot create agents.
                </p>
            </Notice>
        {/if}

        <Notice kind="warn" title="Less isolated than a built-in agent">
            <p class="sm">
                A container agent is less isolated than a built-in agent. It shares the node's kernel and is one
                long-running process for all conversations, so one person's data can leak into another person's answer
                through the agent's own memory. The platform runs it as a non-root user with a read-only file system and
                no Kubernetes token. It may reach only DNS, the model gateway and its tool profile. If the cluster's
                network plugin does not enforce network policy (kind does not for the internet), it can reach any host.
            </p>
        </Notice>

        {#if saveError}
            <Notice kind="error" title="Not created" alert><p class="sm">{saveError}</p></Notice>
        {/if}
        {#if predicted.length}
            <Notice kind="warn" title="This agent would be refused">
                <p class="sm">
                    A check against the platform catalog and policy. The controller decides after you create it.
                </p>
                <ul data-testid="predicted">
                    {#each predicted as p (p.message)}<li>{p.message}</li>{/each}
                </ul>
            </Notice>
        {/if}
        {#if schemaErrors.length}
            <Notice kind="refused" title="The Kubernetes API would refuse this">
                <ul>
                    {#each schemaErrors as s (s)}<li>{s}</li>{/each}
                </ul>
            </Notice>
        {/if}
        {#if checkFailed}
            <Notice kind="error" title="The check could not run"><p class="sm">{checkFailed}</p></Notice>
        {/if}

        <div class="bgrid">
            <div class="stack">
                <div class="panel">
                    <div class="hd"><h2>Identity</h2></div>
                    <div class="bd stack">
                        <div class="grid g2">
                            <TextField
                                label="Name"
                                bind:value={draft.name}
                                mono
                                readonly={readOnly}
                                maxlength={MAX_NAME + 10}
                                error={shown('name')}
                                oninput={touch('name')}
                                hint="Lower case letters, digits and dashes. It cannot change later."
                                id="f-name"
                            />
                            <TextField label="Namespace" value={session?.namespace ?? ''} readonly mono id="f-ns" />
                        </div>
                        <TextField
                            label="Description"
                            bind:value={draft.description}
                            readonly={readOnly}
                            hint="One line about what the agent does."
                            counter={counterText([...draft.description].length, MAX_DESCRIPTION)}
                            counterOver={[...draft.description].length > MAX_DESCRIPTION}
                            id="f-desc"
                        />
                    </div>
                </div>

                <div class="panel">
                    <div class="hd"><h2>Container</h2></div>
                    <div class="bd stack">
                        <TextField
                            label="Image"
                            bind:value={draft.image}
                            mono
                            readonly={readOnly}
                            placeholder={example}
                            error={shown('image')}
                            oninput={touch('image')}
                            hint={`Must be pinned by digest, not by a tag. Example: ${example}`}
                            id="f-image"
                        />
                        <TextField
                            label="Port"
                            bind:value={draft.port}
                            readonly={readOnly}
                            error={shown('port')}
                            oninput={touch('port')}
                            hint="The port your agent listens on, {MIN_PORT} to {MAX_PORT}, on all addresses (0.0.0.0)."
                            id="f-port"
                        />
                        <fieldset class="stack" aria-describedby="env-hint">
                            <legend class="flabel">Environment variables</legend>
                            <p class="sm t3" id="env-hint">
                                Plain values only, at most {MAX_ENV_VARS}. Never put a key or a password here: a value
                                shaped like a secret is refused. The platform sets OPENAI_BASE_URL, OPENAI_API_KEY and
                                OPENAGENTIX_MODEL itself.
                            </p>
                            {#each draft.env as row, i (i)}
                                <div class="grid g2 items-start">
                                    <TextField
                                        label="Variable {i + 1} name"
                                        bind:value={row.name}
                                        mono
                                        readonly={readOnly}
                                        placeholder="LOG_LEVEL"
                                        oninput={touch('env')}
                                    />
                                    <TextField
                                        label="Variable {i + 1} value"
                                        bind:value={row.value}
                                        mono
                                        readonly={readOnly}
                                        oninput={touch('env')}
                                    />
                                </div>
                                {#if !readOnly}
                                    <div>
                                        <Button small variant="ghost" onclick={() => removeVar(i)}
                                            >Remove variable {i + 1}</Button
                                        >
                                    </div>
                                {/if}
                            {/each}
                            {#if shown('env')}
                                <div class="err" role="alert">
                                    <svg class="i" aria-hidden="true"><use href="#s-refused" /></svg><span
                                        >{shown('env')}</span
                                    >
                                </div>
                            {/if}
                            {#if !readOnly}
                                <div>
                                    <Button
                                        small
                                        onclick={addVar}
                                        disabledReason={draft.env.length >= MAX_ENV_VARS
                                            ? `At most ${MAX_ENV_VARS} variables.`
                                            : undefined}>Add variable</Button
                                    >
                                </div>
                            {/if}
                        </fieldset>
                    </div>
                </div>
            </div>

            <div class="stack">
                <div class="panel">
                    <div class="hd"><h2>Model and tools</h2></div>
                    <div class="bd stack">
                        <SelectField
                            label="Model"
                            id="f-model"
                            bind:value={draft.model}
                            disabled={readOnly}
                            error={shown('model')}
                            onchange={touch('model')}
                            hint="Gateway models the platform policy allows. The agent gets the name as OPENAGENTIX_MODEL. It is a hint, not a limit."
                            options={modelOptions(platform)}
                        />
                        <SelectField
                            label="Tool profile"
                            id="f-prof"
                            bind:value={draft.toolProfile}
                            disabled={readOnly}
                            error={shown('toolProfile')}
                            onchange={touch('toolProfile')}
                            hint="Optional. Only profiles the operator opened to container agents can be chosen. The agent gets every tool of the profile."
                            options={containerProfileOptions(platform)}
                        />
                    </div>
                </div>
                <div class="panel">
                    <div class="hd"><h2>What the platform does not do for you</h2></div>
                    <div class="bd">
                        <ul class="sm">
                            <li>
                                The prompt, memory, knowledge, notify, skills and extra outbound hosts are not set here.
                                Your image does that itself.
                            </li>
                            <li>
                                The image is pulled from a registry that needs no login. Private registries are not
                                supported yet.
                            </li>
                            <li>
                                The console never shows or stores a key. The agent's model key is made by the platform
                                and is never read back.
                            </li>
                        </ul>
                    </div>
                </div>
            </div>
        </div>
    {/if}
</section>
