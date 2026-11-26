<script lang="ts">
    import { goto } from '$app/navigation';
    import { api, ApiError, describeError } from '$lib/api';
    import { ctx } from '$lib/context.svelte';
    import {
        addedPrompts,
        bucketPredictions,
        bucketSentences,
        byteLength,
        counterText,
        draftFromSpec,
        emptyDraft,
        featureState,
        MAX_DESCRIPTION,
        MAX_EGRESS,
        MAX_INSTRUCTIONS_BYTES,
        MAX_NAME,
        MAX_SKILLS,
        memoryMax,
        modelOptions,
        nameProblem,
        noProfileAvailable,
        nearLimit,
        originShapeProblem,
        originsInSentences,
        profileOptions,
        sameSpec,
        scanSecrets,
        secretSentence,
        skillStates,
        specFromDraft,
        toolRows,
        type Draft,
        type FieldKey,
    } from '$lib/draft';
    import { isTypingTarget } from '$lib/nav';
    import { startPolling } from '$lib/poll.svelte';
    import { absoluteTime, conditionViews, formatTime, unsettled } from '$lib/status';
    import { toasts } from '$lib/toast.svelte';
    import type { Detail, Prediction, Spec } from '$lib/types';
    import { changedLines, renderSpecYaml } from '$lib/yaml';
    import Button from './Button.svelte';
    import Checkbox from './Checkbox.svelte';
    import CodeViewer from './CodeViewer.svelte';
    import ConditionRail from './ConditionRail.svelte';
    import Dialog from './Dialog.svelte';
    import EmptyState from './EmptyState.svelte';
    import Icon from './Icon.svelte';
    import Notice from './Notice.svelte';
    import PageHeader from './PageHeader.svelte';
    import Segmented from './Segmented.svelte';
    import SelectField from './SelectField.svelte';
    import SideSheet from './SideSheet.svelte';
    import Skeleton from './Skeleton.svelte';
    import StatusBadge from './StatusBadge.svelte';
    import Switch from './Switch.svelte';
    import Tabs from './Tabs.svelte';
    import Tag from './Tag.svelte';
    import TextArea from './TextArea.svelte';
    import TextField from './TextField.svelte';

    interface Props {
        /** The agent to open; absent for a new agent. */
        name?: string;
    }
    let { name }: Props = $props();
    const isNew = $derived(!name);

    const platform = $derived(ctx.platform);
    const session = $derived(ctx.session);

    let detail = $state<Detail | null>(null);
    let loading = $state(false);
    let loadError = $state('');
    let draft = $state<Draft>(emptyDraft(ctx.platform ?? undefined));
    let baseline = $state<Spec | null>(null);
    let tab = $state('build');
    let busy = $state(false);
    let saveError = $state('');
    let conflict = $state(false);
    let remoteChanged = $state(false);
    let predicted = $state<Prediction[]>([]);
    let schemaErrors = $state<string[]>([]);
    let yamlOpen = $state(false);
    let yamlView = $state('cluster');
    let deleteOpen = $state(false);
    let deleteText = $state('');
    let deleteBusy = $state(false);
    let egressInput = $state('');
    let egressError = $state('');
    let awaitingVerdict = $state(false);
    let refusedNotice: Notice | undefined = $state();
    let prompts = $state(false);

    // ---- loading ----

    async function load(initial: boolean) {
        if (!name) return;
        if (initial) {
            loading = true;
            loadError = '';
        }
        try {
            const d = await api.agent(name);
            if (initial || !detail) adopt(d);
            else follow(d);
        } catch (e) {
            if (initial) loadError = describeError('read', name, e);
        } finally {
            loading = false;
        }
    }

    function adopt(d: Detail) {
        detail = d;
        if (d.spec) {
            draft = draftFromSpec(d.name, d.spec);
            baseline = specFromDraft(draft);
        }
    }

    /** A refresh while the status settles. The draft is never overwritten; the version is adopted only when the spec did not change under it. */
    function follow(d: Detail) {
        const old = detail;
        const specChanged = !!d.spec && !!baseline && !sameSpec(specFromDraft(draftFromSpec(d.name, d.spec)), baseline);
        if (specChanged && dirty) {
            remoteChanged = true;
            detail = { ...d, resourceVersion: old?.resourceVersion };
        } else if (specChanged) {
            adopt(d);
        } else {
            detail = d;
        }
        if (awaitingVerdict && d.state === 'refused') {
            awaitingVerdict = false;
            queueMicrotask(() => refusedNotice?.focus());
        } else if (awaitingVerdict && d.state !== 'pending') awaitingVerdict = false;
    }

    $effect(() => {
        const n = name;
        detail = null;
        baseline = null;
        saveError = '';
        conflict = false;
        remoteChanged = false;
        predicted = [];
        tab = 'build';
        if (n) {
            loading = true;
            void load(true);
        } else {
            loading = false;
            draft = emptyDraft(ctx.platform ?? undefined);
            baseline = null;
        }
    });
    // a new draft starts from the platform's first allowed model once the platform is known
    $effect(() => {
        if (isNew && platform && draft.model === '' && !dirtyNew) draft = emptyDraft(platform);
    });

    const poller = startPolling({
        run: () => load(false),
        active: () => !!detail && detail.source === 'built' && unsettled(detail, detail.status?.observedGeneration),
    });
    $effect(() => {
        void detail;
        poller.kick();
        return undefined;
    });
    $effect(() => () => poller.stop());

    // ---- derived state ----

    const chart = $derived(detail?.source === 'chart');
    // a container agent (ADR 0015) is made in "Bring your own agent"; this form has no control for its image, so it shows it only
    const containerAgent = $derived(detail?.runtimeType === 'container' || detail?.spec?.runtime?.type === 'container');
    const containerOf = $derived(detail?.spec?.runtime?.container);
    const readOnly = $derived(chart || containerAgent || (!!session && !session.canWrite));
    // spec fields the stored object has and this form has no control for; a save keeps them
    const unmanaged = $derived(detail?.unmanaged ?? []);
    const promptFromConfigMap = $derived(unmanaged.includes('instructionsFrom'));
    const otherUnmanaged = $derived(unmanaged.filter((k) => k !== 'instructionsFrom' && k !== 'runtime'));
    const spec = $derived(specFromDraft(draft));
    const dirty = $derived(baseline ? !sameSpec(spec, baseline) : false);
    const dirtyNew = $derived(isNew && (draft.name !== '' || draft.instructions !== '' || draft.description !== ''));
    const violations = $derived(detail?.status?.violations ?? []);
    const refused = $derived(detail?.state === 'refused' && violations.length > 0);
    const conditions = $derived(detail?.status?.conditions ?? detail?.conditions ?? []);
    const views = $derived(conditionViews(conditions));

    // ---- live prediction ----

    let timer: ReturnType<typeof setTimeout> | undefined;
    $effect(() => {
        if (!platform || readOnly || loading) return;
        const body = specFromDraft(draft);
        const n = isNew ? draft.name : (name ?? '');
        if (!isNew && !dirty) {
            predicted = [];
            schemaErrors = [];
            return;
        }
        const ctl = new AbortController();
        clearTimeout(timer);
        timer = setTimeout(async () => {
            try {
                const r = await api.validate(n, body, ctl.signal);
                predicted = r.predicted;
                schemaErrors = r.schema.ok ? [] : r.schema.errors;
            } catch (e) {
                void e; // a failed prediction leaves the last one in place; saving still works
            }
        }, 600);
        return () => {
            clearTimeout(timer);
            ctl.abort();
        };
    });

    const secrets = $derived(scanSecrets(draft.instructions));
    const instrBytes = $derived(byteLength(draft.instructions));
    const showPredictions = $derived(isNew || dirty);
    const fieldMsgs = $derived.by(() => {
        // a local map built and returned inside $derived.by: not state, so no reactive Map is needed
        // eslint-disable-next-line svelte/prefer-svelte-reactivity
        const m = new Map<FieldKey, string[]>();
        const add = (b: Map<FieldKey, string[]>) => {
            for (const [k, v] of b) m.set(k, [...(m.get(k) ?? []), ...v]);
        };
        if (refused && !dirty) add(bucketSentences(violations));
        if (showPredictions) add(bucketPredictions(predicted));
        return m;
    });
    const msg = (k: FieldKey) => fieldMsgs.get(k)?.join(' ') ?? '';
    const refusedOrigins = $derived(originsInSentences([...(fieldMsgs.get('egress.allow') ?? [])]));
    const showPredictedNotice = $derived(showPredictions && predicted.length > 0);
    const nameError = $derived(isNew ? nameProblem(draft.name, platform ?? undefined) : '');
    const tools = $derived(platform ? toolRows(platform, draft.toolProfile, draft.tools) : []);
    const profileTools = $derived(platform?.profiles.find((p) => p.name === draft.toolProfile));
    const added = $derived(platform ? addedPrompts(platform, draft) : []);
    const memState = $derived(platform ? featureState(platform, 'memory') : { disabled: false });
    const knState = $derived(platform ? featureState(platform, 'knowledge') : { disabled: false });
    const noState = $derived(platform ? featureState(platform, 'notify') : { disabled: false });
    const ttlNumber = $derived(Number.parseInt(draft.memoryTtl, 10));

    // ---- form handlers ----

    function setProfile() {
        // tools the new profile does not offer would only be refused: drop them
        const offered = new Set(profileTools?.tools ?? []);
        draft.tools = draft.tools.filter((t) => offered.has(t));
    }
    function toggleTool(t: string, on: boolean) {
        draft.tools = on ? [...draft.tools.filter((x) => x !== t), t] : draft.tools.filter((x) => x !== t);
    }
    function toggleSkill(s: string, on: boolean) {
        draft.skills = on ? [...draft.skills.filter((x) => x !== s), s] : draft.skills.filter((x) => x !== s);
    }
    function addOrigin() {
        const o = egressInput.trim();
        if (!o) return;
        const bad = originShapeProblem(o);
        if (bad) {
            egressError = bad;
            return;
        }
        if (draft.egress.includes(o)) {
            egressError = `${o} is already in the list`;
            return;
        }
        if (draft.egress.length >= MAX_EGRESS) {
            egressError = `At most ${MAX_EGRESS} origins are allowed`;
            return;
        }
        draft.egress = [...draft.egress, o];
        egressInput = '';
        egressError = '';
    }
    function originKey(e: KeyboardEvent) {
        if (e.key === 'Enter') {
            e.preventDefault();
            addOrigin();
        }
    }

    // ---- save ----

    const saveLabel = $derived(
        isNew ? (showPredictedNotice ? 'Create anyway' : 'Create agent') : showPredictedNotice ? 'Save anyway' : 'Save',
    );
    /** Set when the policy requires a tool profile and the builder has none to offer: nothing could be saved. */
    const noProfile = $derived(platform ? noProfileAvailable(platform) : undefined);
    const saveBlock = $derived.by(() => {
        if (isNew && !draft.name) return 'Give the agent a name first.';
        if (isNew && nameError) return nameError;
        if (!draft.model) return 'Choose a model first.';
        if (isNew && noProfile) return noProfile;
        if (!promptFromConfigMap && !draft.instructions.trim()) return 'Write the instructions first.';
        if (!isNew && !dirty) return 'Nothing to save: the form matches the cluster.';
        return undefined;
    });

    async function save() {
        if (busy || readOnly) return;
        if (saveBlock) {
            toasts.info(saveBlock);
            return;
        }
        busy = true;
        saveError = '';
        conflict = false;
        const subject = isNew ? draft.name : (name ?? '');
        try {
            if (isNew) {
                const d = await api.create({ name: draft.name, spec });
                toasts.success(`Created ${d.name}. Waiting for the controller.`);
                awaitingVerdict = true;
                await goto(`/agents/${encodeURIComponent(d.name)}`, { replaceState: true });
            } else {
                const d = await api.update(subject, { name: subject, resourceVersion: detail?.resourceVersion, spec });
                adopt(d);
                remoteChanged = false;
                awaitingVerdict = true;
                toasts.success(`Saved ${subject}. Waiting for the controller.`);
                poller.kick();
            }
        } catch (e) {
            if (e instanceof ApiError && e.status === 409 && e.code === 'conflict') {
                conflict = true;
                saveError = describeError('save', subject, e);
            } else if (e instanceof ApiError && e.status === 401) {
                /* the client signed out; the sign-in page is showing */
            } else {
                saveError = describeError(isNew ? 'create' : 'save', subject, e);
                toasts.error(saveError);
            }
        } finally {
            busy = false;
        }
    }

    /** After a conflict: take the newest version, and either keep the draft or drop it. */
    async function reload(keepDraft: boolean) {
        if (!name) return;
        try {
            const d = await api.agent(name);
            if (keepDraft) {
                const mine = $state.snapshot(draft);
                adopt(d);
                draft = mine;
            } else adopt(d);
            conflict = false;
            remoteChanged = false;
            saveError = '';
        } catch (e) {
            saveError = describeError('read', name, e);
        }
    }

    function onkey(e: KeyboardEvent) {
        if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') {
            e.preventDefault();
            void save();
        } else if (
            e.key === 'y' &&
            !e.ctrlKey &&
            !e.metaKey &&
            !e.altKey &&
            !isTypingTarget(e.target) &&
            detail?.yaml
        ) {
            yamlOpen = true;
        }
    }

    // ---- pause and resume (spec.suspend) ----

    let pauseBusy = $state(false);
    /** Flips spec.suspend on the saved spec. Edits in the form are left alone, so Pause never saves a half-written draft. */
    async function togglePause() {
        if (!name || !detail?.spec || pauseBusy) return;
        const next = !detail.spec.suspend;
        pauseBusy = true;
        try {
            const d = await api.update(name, {
                name,
                resourceVersion: detail.resourceVersion,
                spec: { ...detail.spec, suspend: next },
            });
            detail = d;
            draft.suspend = next;
            if (baseline) baseline = { ...baseline, ...(next ? { suspend: true } : {}) };
            if (!next && baseline) delete baseline.suspend;
            toasts.success(next ? `Paused ${name}. It stays, and refuses new work.` : `Resumed ${name}.`);
        } catch (e) {
            saveError = describeError(next ? 'pause' : 'resume', name, e);
            toasts.error(saveError);
        } finally {
            pauseBusy = false;
        }
    }

    // ---- delete ----

    async function confirmDelete() {
        if (!name || deleteText !== name) return;
        deleteBusy = true;
        try {
            await api.remove(name);
            deleteOpen = false;
            toasts.success(`Deleting ${name}. The registry shows it until the controller has finished.`);
            await goto('/agents');
        } catch (e) {
            deleteOpen = false;
            saveError = describeError('delete', name, e);
            toasts.error(saveError);
        } finally {
            deleteBusy = false;
        }
    }

    // ---- yaml ----

    const draftYaml = $derived(
        renderSpecYaml(isNew ? draft.name || 'new-agent' : (name ?? ''), session?.namespace ?? '', spec),
    );
    const clusterYaml = $derived(detail?.spec ? renderSpecYaml(name ?? '', session?.namespace ?? '', detail.spec) : '');
    const changed = $derived(changedLines(clusterYaml, draftYaml));

    const callerYaml = $derived(
        `governance:\n  a2a:\n    callers:\n      - name: ${name ?? 'my-caller'}-caller\n        agents: [${session?.namespace ?? 'kagent'}/${name ?? 'my-agent'}]\n        userIds: {exact: ["kourier:${name ?? 'my-agent'}-hook"]}\n`,
    );
    const generationLine = $derived.by(() => {
        const s = detail?.status;
        if (!detail || !s) return '';
        if (s.observedGeneration < detail.generation)
            return `Status is for generation ${s.observedGeneration}; you are looking at generation ${detail.generation}. Waiting for the controller.`;
        return `Status is for generation ${s.observedGeneration}, the current one.`;
    });
    const resourceStrip = $derived(
        chart
            ? `chart values · agents[] · namespace ${detail?.namespace ?? ''}`
            : `AgentDefinition · openagentix.io/v1alpha1 · namespace ${session?.namespace ?? ''}${detail ? ` · generation ${detail.generation}` : ''}`,
    );
    const title = $derived(isNew ? 'New agent' : (name ?? ''));
</script>

<svelte:window onkeydown={onkey} />
<svelte:head><title>{title} · Agents · OpenAgentix console</title></svelte:head>

<section class="view max-form" aria-busy={loading}>
    <PageHeader
        {title}
        mono={!isNew}
        strip={isNew
            ? 'AgentDefinition · openagentix.io/v1alpha1 · namespace ' + (session?.namespace ?? '')
            : resourceStrip}
    >
        {#snippet badge()}
            {#if detail}<StatusBadge state={detail.state} deleting={detail.deleting} title={detail.stateReason} />{/if}
        {/snippet}
        {#snippet actions()}
            {#if detail?.yaml && !chart}
                <Button onclick={() => (yamlOpen = true)} aria-keyshortcuts="y"><Icon name="i-code" />View YAML</Button>
            {/if}
            {#if !isNew && !readOnly}
                <Button busy={pauseBusy} onclick={togglePause} id="pause-btn"
                    ><Icon name={detail?.suspended ? 'i-chev' : 's-paused'} />{detail?.suspended
                        ? 'Resume'
                        : 'Pause'}</Button
                >
                <Button onclick={() => ((deleteText = ''), (deleteOpen = true))}><Icon name="i-trash" />Delete</Button>
            {/if}
            {#if !readOnly}
                <Button
                    variant="primary"
                    {busy}
                    disabledReason={saveBlock && !busy ? saveBlock : undefined}
                    onclick={save}
                    id="save-btn">{saveLabel}</Button
                >
            {/if}
        {/snippet}
    </PageHeader>

    {#if loadError}
        <Notice kind="error" title="Could not open this agent" alert>
            <p class="sm">{loadError}</p>
            {#snippet action()}<Button small onclick={() => load(true)}>Retry</Button>{/snippet}
        </Notice>
        <p><a href="/agents">Back to the registry</a></p>
    {:else if loading}
        <div aria-busy="true">
            <span class="sr">Loading</span>
            <div class="bgrid">
                <div class="panel">
                    <div class="bd stack">
                        <Skeleton class="w-[30%]" /><Skeleton class="w-full" /><Skeleton class="w-[80%]" /><Skeleton
                            class="!h-40"
                        />
                    </div>
                </div>
                <div class="panel">
                    <div class="bd stack">
                        <Skeleton class="w-[40%]" /><Skeleton class="w-full" /><Skeleton class="w-[60%]" /><Skeleton
                            class="!h-24"
                        />
                    </div>
                </div>
            </div>
        </div>
    {:else}
        {#if detail}<ConditionRail {conditions} />{/if}

        {#if chart}
            <Notice kind="ro" title="Read-only">
                <p class="sm">
                    This agent comes from chart values (<code>agents[]</code>). Change it in your values file and run
                    <code>install.sh</code>.
                </p>
            </Notice>
        {:else if readOnly}
            <Notice kind="ro" title="This console is read-only">
                <p class="sm">
                    The console runs in viewer mode, so it shows definitions but cannot create, change or delete them.
                </p>
            </Notice>
        {/if}

        {#if isNew && platform?.container.available && platform.container.allowed && !readOnly}
            <p class="sm t2" data-testid="byo-link">
                Already have an agent in a container image?
                <a href="/agents/new/container">Bring your own agent</a>.
            </p>
        {/if}

        <Tabs
            label="Agent"
            prefix="b"
            selected={tab}
            tabs={[
                { id: 'build', label: 'Build' },
                { id: 'playground', label: 'Playground' },
                { id: 'deploy', label: 'Deploy' },
            ]}
            onselect={(id) => (tab = id)}
        />

        {#if tab === 'build'}
            <div id="b-panel-build" role="tabpanel" aria-labelledby="b-tab-build" class="stack">
                {#if conflict}
                    <Notice kind="warn" title="This agent changed since you opened it" alert>
                        <p class="sm">{saveError}</p>
                        <div class="acts mt-2">
                            <Button small onclick={() => reload(false)}>Load the latest version</Button>
                            <Button small onclick={() => reload(true)}>Keep my changes on top of the latest</Button>
                        </div>
                    </Notice>
                {:else if saveError}
                    <Notice kind="error" title="Not saved" alert><p class="sm">{saveError}</p></Notice>
                {/if}
                {#if remoteChanged && !conflict}
                    <Notice kind="warn" title="Someone changed this agent while you were editing" alert>
                        <p class="sm">Saving will be refused until you load the latest version.</p>
                        <div class="acts mt-2">
                            <Button small onclick={() => reload(true)}>Keep my changes on top of the latest</Button
                            ><Button small onclick={() => reload(false)}>Load the latest version</Button>
                        </div>
                    </Notice>
                {/if}
                {#if promptFromConfigMap || otherUnmanaged.length}
                    <Notice kind="info" title="Some of this definition is not edited here">
                        <p class="sm" data-testid="unmanaged">
                            {#if promptFromConfigMap}
                                The instructions come from a ConfigMap (<code>instructionsFrom</code>), so they are
                                shown read-only. Change the ConfigMap, or edit the definition with kubectl.
                            {/if}
                            {#if otherUnmanaged.length}
                                The definition also has fields this form does not know ({otherUnmanaged.join(', ')}).
                                They are kept as they are when you save.
                            {/if}
                        </p>
                    </Notice>
                {/if}
                {#if refused}
                    <Notice kind="refused" title="Refused by the platform policy" alert bind:this={refusedNotice}>
                        <p class="sm">
                            {violations.length}
                            {violations.length === 1 ? 'rule' : 'rules'} refused this definition. Nothing was changed in the
                            cluster; objects of an earlier version, if any, are left as they were.
                        </p>
                        <ul data-testid="violations">
                            {#each violations as v (v)}<li>{v}</li>{/each}
                        </ul>
                    </Notice>
                {/if}
                {#if showPredictedNotice}
                    <Notice kind="warn" title="This draft would be refused">
                        <p class="sm">
                            A prediction from the platform catalog and policy. The controller decides after you save.
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
                {#if isNew && noProfile}
                    <Notice kind="warn" title="No tool profile is available">
                        <p class="sm" data-testid="no-profile">
                            {noProfile}
                            <a
                                href="https://openagentix.github.io/reference/platform-catalog"
                                rel="noopener noreferrer"
                                target="_blank">Read how the catalog and policy list profiles</a
                            >.
                        </p>
                    </Notice>
                {/if}
                {#if ctx.platformError}
                    <Notice kind="error" title="The platform catalog could not be read"
                        ><p class="sm">{ctx.platformError}</p></Notice
                    >
                {/if}

                {#if containerAgent}
                    <Notice kind="info" title="This is a container agent">
                        <div data-testid="container-note" class="stack">
                            <p class="sm">
                                It runs your own image, so there are no instructions to edit here. The console shows it
                                and does not change it, so a save can never drop the image. To change the image, the
                                port or the variables, create a new agent from
                                <a href="/agents/new/container">Bring your own agent</a>, or edit the definition with
                                kubectl.
                            </p>
                            <dl class="kv sm">
                                <dt>Image</dt>
                                <dd><code>{containerOf?.image ?? ''}</code></dd>
                                <dt>Port</dt>
                                <dd>{containerOf?.port ?? ''}</dd>
                                {#if containerOf?.env?.length}
                                    <dt>Variables</dt>
                                    <dd>{containerOf.env.map((e) => e.name).join(', ')}</dd>
                                {/if}
                                {#if detail?.isolation}
                                    <dt>Isolation</dt>
                                    <dd>{detail.isolation}</dd>
                                {/if}
                            </dl>
                        </div>
                    </Notice>
                {:else}
                    <div class="bgrid">
                        <div class="panel">
                            <div class="hd"><h2>Identity and instructions</h2></div>
                            <div class="bd stack">
                                <div class="grid g2">
                                    {#if isNew}
                                        <TextField
                                            label="Name"
                                            bind:value={draft.name}
                                            mono
                                            maxlength={MAX_NAME + 10}
                                            error={nameError || msg('name')}
                                            hint="Lower case letters, digits and dashes. It cannot change later."
                                            id="f-name"
                                        />
                                    {:else}
                                        <TextField
                                            label="Name"
                                            value={name ?? ''}
                                            readonly
                                            mono
                                            hint="Names cannot change; create a new agent instead."
                                            id="f-name"
                                        />
                                    {/if}
                                    <TextField
                                        label="Namespace"
                                        value={session?.namespace ?? ''}
                                        readonly
                                        mono
                                        hint="Only {session?.namespace ?? 'kagent'} is reconciled in v1alpha1."
                                        id="f-ns"
                                    />
                                </div>
                                <TextField
                                    label="Description"
                                    bind:value={draft.description}
                                    readonly={readOnly}
                                    hint="One line about what the agent does."
                                    counter={counterText([...draft.description].length, MAX_DESCRIPTION)}
                                    counterOver={[...draft.description].length > MAX_DESCRIPTION}
                                    error={msg('description')}
                                    id="f-desc"
                                />
                                <TextArea
                                    label="Instructions"
                                    bind:value={draft.instructions}
                                    readonly={readOnly || promptFromConfigMap}
                                    rows={11}
                                    hint="The system prompt. Checked for anything shaped like a secret."
                                    counter={counterText(instrBytes, MAX_INSTRUCTIONS_BYTES, 'bytes')}
                                    counterOver={instrBytes > MAX_INSTRUCTIONS_BYTES}
                                    counterLive={nearLimit(instrBytes, MAX_INSTRUCTIONS_BYTES)}
                                    error={secrets.length ? secretSentence(secrets) : msg('instructions')}
                                    id="f-ins"
                                />
                                {#if platform}
                                    <details class="sm" bind:open={prompts}>
                                        <summary class="t2 cursor-pointer"
                                            >Prompts the platform adds ({added.length})</summary
                                        >
                                        <div class="mt-2 stack">
                                            {#if added.length === 0}
                                                <p class="t3">
                                                    Turn on knowledge, notify or memory and the paragraph the platform
                                                    adds to the system prompt shows here.
                                                </p>
                                            {/if}
                                            {#each added as a (a.title)}
                                                <div class="code">
                                                    <pre class="whitespace-pre-wrap"><span class="c"
                                                            ># {a.title} prompt from the platform catalog</span
                                                        >{'\n' + a.text}</pre>
                                                </div>
                                            {/each}
                                        </div>
                                    </details>
                                {/if}
                            </div>
                        </div>

                        <div class="stack">
                            <div class="panel">
                                <div class="hd"><h2>Model and capabilities</h2></div>
                                <div class="bd">
                                    {#if !platform}
                                        <div class="stack">
                                            <Skeleton class="w-[50%]" /><Skeleton class="w-full" /><Skeleton
                                                class="w-[70%]"
                                            />
                                        </div>
                                    {:else}
                                        <div class="cap">
                                            <div class="cx">
                                                <SelectField
                                                    label="Model"
                                                    id="f-model"
                                                    bind:value={draft.model}
                                                    disabled={readOnly}
                                                    error={msg('model')}
                                                    hint="Gateway models the platform policy allows. The catalog has {platform
                                                        .models.length}."
                                                    options={modelOptions(platform)}
                                                />
                                                <SelectField
                                                    label="Tool profile"
                                                    id="f-prof"
                                                    bind:value={draft.toolProfile}
                                                    disabled={readOnly}
                                                    error={msg('toolProfile')}
                                                    onchange={setProfile}
                                                    hint={profileTools
                                                        ? `Served by ${profileTools.toolServer}${profileTools.codeMode ? ' · code mode on' : ''}`
                                                        : 'No tool profile: the agent gets no tools of its own.'}
                                                    options={profileOptions(platform)}
                                                />
                                            </div>
                                        </div>
                                        {#if draft.toolProfile || tools.length}
                                            <div class="cap">
                                                <fieldset class="cx">
                                                    <legend class="flabel"
                                                        >Tools offered by <code
                                                            >{draft.toolProfile || 'no profile'}</code
                                                        ></legend
                                                    >
                                                    {#each tools as t (t.name)}
                                                        <Checkbox
                                                            checked={draft.tools.includes(t.name)}
                                                            disabled={readOnly}
                                                            bad={t.foreign}
                                                            onchange={(v) => toggleTool(t.name, v)}
                                                            reason={t.foreign
                                                                ? `not offered by ${draft.toolProfile || 'any profile'}`
                                                                : undefined}
                                                        >
                                                            {#if t.code}
                                                                <code>execute_tool_script</code>
                                                                <span class="sm t3"
                                                                    >Code mode: the model writes a short script that
                                                                    calls several tools in one step</span
                                                                >
                                                            {:else}
                                                                <code><span class="dim">{t.prefix}</span>{t.rest}</code>
                                                            {/if}
                                                        </Checkbox>
                                                    {:else}
                                                        <span class="sm t3">The profile offers no tools.</span>
                                                    {/each}
                                                    {#if msg('tools')}<div class="prev">
                                                            <Icon name="s-refused" size={13} /><span
                                                                >{msg('tools')}</span
                                                            >
                                                        </div>{/if}
                                                </fieldset>
                                            </div>
                                        {/if}
                                        <div class="cap">
                                            <div class="cx">
                                                <span class="flabel" id="lk">Knowledge</span>
                                                <span class="sm t3" id="lk-d">
                                                    {#if knState.disabled}{knState.reason}.{:else}Adds {platform
                                                            .knowledge.tools.length} knowledge tools and a prompt to search
                                                        the knowledge base and cite documents.{/if}
                                                </span>
                                                {#if draft.knowledge}<span class="sm t3" data-testid="collections"
                                                        >Collections: {draft.knowledgeCollections.length
                                                            ? draft.knowledgeCollections.join(', ')
                                                            : 'none (collections come with their own kind)'}</span
                                                    >{/if}
                                                {#if msg('knowledge')}<div class="prev">
                                                        <Icon name="s-refused" size={13} /><span
                                                            >{msg('knowledge')}</span
                                                        >
                                                    </div>{/if}
                                            </div>
                                            <Switch
                                                labelledby="lk"
                                                describedby="lk-d"
                                                bind:checked={draft.knowledge}
                                                disabled={readOnly || (knState.disabled && !draft.knowledge)}
                                            />
                                        </div>
                                        <div class="cap">
                                            <div class="cx">
                                                <span class="flabel" id="ln">Notify</span>
                                                <span class="sm t3" id="ln-d">
                                                    {#if noState.disabled}{noState.reason}.{:else}The agent can send a
                                                        message to a named destination when a task asks it to.{/if}
                                                </span>
                                                {#if draft.notify}<span class="sm t3" data-testid="destinations"
                                                        >Destinations: {draft.notifyDestinations.length
                                                            ? draft.notifyDestinations.join(', ')
                                                            : 'none (destinations come with their own kind)'}</span
                                                    >{/if}
                                                {#if msg('notify')}<div class="prev">
                                                        <Icon name="s-refused" size={13} /><span>{msg('notify')}</span>
                                                    </div>{/if}
                                            </div>
                                            <Switch
                                                labelledby="ln"
                                                describedby="ln-d"
                                                bind:checked={draft.notify}
                                                disabled={readOnly || (noState.disabled && !draft.notify)}
                                            />
                                        </div>
                                        <div class="cap">
                                            <div class="cx">
                                                <span class="flabel" id="lm">Memory</span>
                                                <span class="sm t3" id="lm-d">
                                                    {#if memState.disabled}{memState.reason}.{:else}Remembers facts per
                                                        user across conversations.{/if}
                                                </span>
                                                {#if draft.memoryEnabled}
                                                    <div class="mt-1 max-w-[260px]">
                                                        <label for="f-ttl" class="sm font-semibold"
                                                            >Keep memories for</label
                                                        >
                                                        <div class="flex items-center gap-2">
                                                            <input
                                                                id="f-ttl"
                                                                class="input !w-20"
                                                                type="number"
                                                                min="1"
                                                                max={memoryMax(platform)}
                                                                bind:value={draft.memoryTtl}
                                                                readonly={readOnly}
                                                                aria-describedby="f-ttl-h"
                                                                aria-invalid={msg('memory.ttlDays')
                                                                    ? 'true'
                                                                    : undefined}
                                                            />
                                                            <span class="sm t2">days</span>
                                                        </div>
                                                        <div class="hint mt-1" id="f-ttl-h">
                                                            <span
                                                                >1 to {memoryMax(platform)} days, platform maximum. {draft.memoryTtl ===
                                                                ''
                                                                    ? `Empty means the catalog default (${platform.memory.defaultTtlDays}).`
                                                                    : ''}{Number.isFinite(ttlNumber) &&
                                                                ttlNumber > memoryMax(platform)
                                                                    ? ' Above the maximum.'
                                                                    : ''}</span
                                                            >
                                                        </div>
                                                    </div>
                                                {/if}
                                                {#if msg('memory') || msg('memory.ttlDays')}<div class="prev">
                                                        <Icon name="s-refused" size={13} /><span
                                                            >{[msg('memory'), msg('memory.ttlDays')]
                                                                .filter(Boolean)
                                                                .join(' ')}</span
                                                        >
                                                    </div>{/if}
                                            </div>
                                            <Switch
                                                labelledby="lm"
                                                describedby="lm-d"
                                                bind:checked={draft.memoryEnabled}
                                                disabled={readOnly || (memState.disabled && !draft.memoryEnabled)}
                                            />
                                        </div>
                                        <div class="cap">
                                            <fieldset class="cx">
                                                <legend class="flabel">Skills</legend>
                                                {#each skillStates(platform) as s (s.name)}
                                                    <Checkbox
                                                        checked={draft.skills.includes(s.name)}
                                                        disabled={readOnly ||
                                                            (s.disabled && !draft.skills.includes(s.name))}
                                                        reason={s.reason}
                                                        onchange={(v) => toggleSkill(s.name, v)}
                                                    >
                                                        <code>{s.name}</code>
                                                        <span class="sm t3">{s.disabled ? '' : 'approved'}</span>
                                                    </Checkbox>
                                                {:else}
                                                    <span class="sm t3">The platform catalog has no skills.</span>
                                                {/each}
                                                {#if draft.skills.length > MAX_SKILLS}<div class="prev">
                                                        <Icon name="s-refused" size={13} /><span
                                                            >At most {MAX_SKILLS} skills.</span
                                                        >
                                                    </div>{/if}
                                                {#if msg('skills')}<div class="prev">
                                                        <Icon name="s-refused" size={13} /><span>{msg('skills')}</span>
                                                    </div>{/if}
                                            </fieldset>
                                        </div>
                                        <div class="cap">
                                            <div class="cx gap-1.5">
                                                <span class="flabel" id="le">Egress</span>
                                                {#if draft.egress.length}
                                                    <div class="tags" role="list" aria-labelledby="le">
                                                        {#each draft.egress as o (o)}
                                                            <span role="listitem">
                                                                <Tag
                                                                    variant={refusedOrigins.has(o)
                                                                        ? 'refused'
                                                                        : 'neutral'}
                                                                    removeLabel="Remove {o}"
                                                                    onremove={readOnly
                                                                        ? undefined
                                                                        : () =>
                                                                              (draft.egress = draft.egress.filter(
                                                                                  (x) => x !== o,
                                                                              ))}>{o}</Tag
                                                                >
                                                            </span>
                                                        {/each}
                                                    </div>
                                                {:else}
                                                    <span class="sm t3">No outbound access</span>
                                                {/if}
                                                {#if !readOnly}
                                                    <div class="tag-input">
                                                        <input
                                                            class="input !h-7 grow"
                                                            placeholder="https://host[:port]"
                                                            aria-label="Add an origin"
                                                            bind:value={egressInput}
                                                            onkeydown={originKey}
                                                            aria-invalid={egressError ? 'true' : undefined}
                                                            aria-describedby={egressError ? 'f-eg-err' : undefined}
                                                            autocomplete="off"
                                                            spellcheck="false"
                                                        />
                                                        <Button small onclick={addOrigin}>Add</Button>
                                                    </div>
                                                {/if}
                                                {#if egressError}<div class="field">
                                                        <div class="err" id="f-eg-err">
                                                            <Icon name="s-refused" size={13} /><span>{egressError}</span
                                                            >
                                                        </div>
                                                    </div>{/if}
                                                <span class="sm t3"
                                                    >The policy allows {#each platform.policy.egress.allowedOrigins as o, i (o)}{#if i > 0}{i ===
                                                            platform.policy.egress.allowedOrigins.length - 1
                                                                ? ' and '
                                                                : ', '}{/if}<code>{o}</code>{:else}no origin{/each}.
                                                    Nothing else is reachable.</span
                                                >
                                                {#if msg('egress.allow')}<div class="prev">
                                                        <Icon name="s-refused" size={13} /><span
                                                            >{msg('egress.allow')}</span
                                                        >
                                                    </div>{/if}
                                            </div>
                                        </div>
                                        <p class="sm t3 border-t border-border pt-3">
                                            Model access, image, tool server and budget come from the platform. Callers
                                            are set by an operator in the gate rules.
                                        </p>
                                    {/if}
                                </div>
                            </div>

                            <div class="panel">
                                <div class="hd">
                                    <h2>Platform policy</h2>
                                    <a class="sm ml-auto" href="/governance">Governance</a>
                                </div>
                                <div class="bd">
                                    {#if platform}
                                        <dl class="kv sm" data-testid="policy">
                                            <dt>Models</dt>
                                            <dd class="commas">
                                                {#each platform.policy.allowedModels as m (m)}<code>{m}</code>{/each}
                                            </dd>
                                            <dt>Tool profiles</dt>
                                            <dd class="commas">
                                                {#each platform.policy.allowedProfiles as m (m)}<code>{m}</code
                                                    >{/each}{platform.policy.requireToolProfile ? ' (required)' : ''}
                                            </dd>
                                            <dt>Knowledge, notify</dt>
                                            <dd>
                                                {platform.policy.allowKnowledge
                                                    ? 'knowledge allowed'
                                                    : 'knowledge not allowed'}, {platform.policy.allowNotify
                                                    ? 'notify allowed'
                                                    : 'notify not allowed'}
                                            </dd>
                                            <dt>Memory</dt>
                                            <dd>
                                                {platform.policy.memory.allowed
                                                    ? `allowed, at most ${platform.policy.memory.maxTtlDays} days${platform.policy.memory.requireExpiry ? ', expiry required' : ''}`
                                                    : 'not allowed'}
                                            </dd>
                                            <dt>Skills</dt>
                                            <dd class="commas">
                                                {#each platform.policy.allowedSkills as m (m)}<code>{m}</code
                                                    >{:else}none{/each}
                                            </dd>
                                            <dt>Egress</dt>
                                            <dd class="commas">
                                                {#each platform.policy.egress.allowedOrigins as m (m)}<code>{m}</code
                                                    >{:else}none{/each}
                                            </dd>
                                            {#if platform.policy.egress.inClusterDestinations?.length}
                                                <dt>In-cluster</dt>
                                                <dd class="commas">
                                                    {#each platform.policy.egress.inClusterDestinations as d (d)}<code
                                                            >{d}</code
                                                        >{/each}
                                                </dd>
                                            {/if}
                                            <dt>Agents</dt>
                                            <dd>up to {platform.policy.maxAgents} definitions</dd>
                                        </dl>
                                    {:else}
                                        <p class="sm t3">{ctx.platformError ?? 'Loading the platform policy.'}</p>
                                    {/if}
                                </div>
                            </div>
                        </div>
                    </div>
                {/if}

                {#if detail && detail.status}
                    <div class="panel" id="status-panel">
                        <div class="hd">
                            <h2>Status</h2>
                            <span class="sm t3" id="genLine">{generationLine}</span>
                        </div>
                        <div class="tw">
                            <table>
                                <thead
                                    ><tr
                                        ><th>Condition</th><th>Status</th><th>Reason</th><th>Message</th><th class="r"
                                            >Last change</th
                                        ></tr
                                    ></thead
                                >
                                <tbody>
                                    {#each views as v (v.type)}
                                        <tr>
                                            <td>{v.type}</td>
                                            <td>
                                                {#if v.kind === 'none'}<span class="t3">{v.status}</span>{:else}<span
                                                        class="badge st-{v.kind}"
                                                        ><svg aria-hidden="true"
                                                            ><use
                                                                href="#{v.kind === 'ready'
                                                                    ? 's-ready'
                                                                    : v.kind === 'pending'
                                                                      ? 's-pending'
                                                                      : v.kind === 'refused'
                                                                        ? 's-refused'
                                                                        : 's-error'}"
                                                            /></svg
                                                        >{v.status}</span
                                                    >{/if}
                                            </td>
                                            <td class="mono"
                                                >{#if v.reason}{v.reason}{:else}<span class="t3">—</span>{/if}</td
                                            >
                                            <td class="sm t2"
                                                >{#if v.message}{v.message}{:else}<span class="t3">None</span>{/if}</td
                                            >
                                            <td class="r sm t3" title={absoluteTime(v.time)}>{formatTime(v.time)}</td>
                                        </tr>
                                    {/each}
                                </tbody>
                            </table>
                        </div>
                        <div class="bd border-t border-border">
                            <dl class="kv">
                                <dt>Endpoint</dt>
                                <dd>
                                    {#if detail.status.endpoint?.url}<code>{detail.status.endpoint.url}</code>
                                        <span class="sm t3"
                                            >{detail.status.endpoint.protocol ?? ''}
                                            {detail.status.endpoint.protocolVersion ?? ''}</span
                                        >{:else}<span class="t3">None, the A2A gate is off</span>{/if}
                                </dd>
                                <dt>Revision</dt>
                                <dd>
                                    {#if detail.status.revision}<code>{detail.status.revision}</code>{:else}<span
                                            class="t3">None yet</span
                                        >{/if}
                                </dd>
                                <dt>Effective tools</dt>
                                <dd>
                                    {#if detail.status.effectiveTools.length}<div class="tags">
                                            {#each detail.status.effectiveTools as t (t)}<Tag>{t}</Tag>{/each}
                                        </div>{:else}<span class="t3">None</span>{/if}
                                </dd>
                                <dt>Effective egress</dt>
                                <dd>
                                    {#if detail.status.effectiveEgress.length}{#each detail.status.effectiveEgress as t (t)}<code
                                                >{t}</code
                                            >{/each}{:else}<span class="t3">None</span>{/if}
                                </dd>
                                <dt>Runtime object</dt>
                                <dd>
                                    {#if detail.status.agentRef}<code
                                            >{detail.status.agentRef.apiVersion}
                                            {detail.status.agentRef.kind}
                                            {detail.status.agentRef.name}</code
                                        >{:else}<span class="t3">None</span>{/if}
                                </dd>
                                {#if detail.status.capabilities}
                                    <dt>Capabilities</dt>
                                    <dd><code>{JSON.stringify(detail.status.capabilities)}</code></dd>
                                {/if}
                            </dl>
                            {#if detail.status.controller && Object.keys(detail.status.controller).length}
                                <details class="sm mt-3" data-testid="controller-details">
                                    <summary class="t2 cursor-pointer"
                                        >Controller details (internal, may change without notice)</summary
                                    >
                                    <dl class="kv sm mt-2">
                                        {#each Object.entries(detail.status.controller) as [k, v] (k)}
                                            <dt>{k}</dt>
                                            <dd><code>{typeof v === 'string' ? v : JSON.stringify(v)}</code></dd>
                                        {/each}
                                    </dl>
                                </details>
                            {/if}
                        </div>
                    </div>
                {:else if chart && detail}
                    <div class="panel">
                        <div class="hd"><h2>Status</h2></div>
                        <div class="bd">
                            <dl class="kv">
                                <dt>Runtime</dt>
                                <dd>
                                    {#if detail.stateReason}{detail.stateReason}{:else}Ready{/if}
                                </dd>
                            </dl>
                        </div>
                    </div>
                {/if}
            </div>
        {:else if tab === 'playground'}
            <div id="b-panel-playground" role="tabpanel" aria-labelledby="b-tab-playground" class="stack">
                <Notice kind="ro" title="The playground is not available yet">
                    <p class="sm">
                        Sending a message goes through the A2A gate as caller <code>console</code>, which a later slice
                        of ADR 0007 adds. Until then, call the agent through the gate with a caller rule.
                    </p>
                </Notice>
            </div>
        {:else}
            <div id="b-panel-deploy" role="tabpanel" aria-labelledby="b-tab-deploy" class="stack">
                <Notice kind="warn" title="Callers come from the gate rules">
                    <p class="sm">
                        The console does not read or write gate rules. An operator adds a caller rule with <code
                            >agents: [{session?.namespace ?? 'kagent'}/{name ?? 'my-agent'}]</code
                        >; until one exists, assume nobody can call this agent.
                    </p>
                </Notice>
                <div class="grid g2">
                    <div class="panel">
                        <div class="hd"><h2>Objects the runtime adapter owns</h2></div>
                        {#if detail && detail.objects.length}
                            <div class="tw">
                                <table class="!min-w-0">
                                    <thead><tr><th>Kind</th><th>Name</th><th>Status</th></tr></thead>
                                    <tbody>
                                        {#each detail.objects as o (o.kind + (o.name ?? ''))}
                                            <tr>
                                                <td>{o.kind}</td>
                                                <td class="mono"
                                                    >{#if o.name}{o.name}{:else}<span class="t3"
                                                            >named by the adapter</span
                                                        >{/if}</td
                                                >
                                                <td
                                                    >{#if o.state === 'ready' || o.state === 'pending'}<StatusBadge
                                                            state={o.state}
                                                        />{:else}<span class="sm t3">{o.note}</span>{/if}</td
                                                >
                                            </tr>
                                        {/each}
                                    </tbody>
                                </table>
                            </div>
                            <div class="bd sm t3">
                                Labels <code>app.kubernetes.io/managed-by: openagentix-control-plane</code>,
                                <code>openagentix.io/agent-definition: {name}</code>
                            </div>
                        {:else}
                            <EmptyState title="Nothing is deployed for this agent" icon="i-info" level={3}>
                                <p>
                                    {isNew
                                        ? 'Create the agent and the controller makes its objects.'
                                        : chart
                                          ? 'Chart agents are made by Helm, not by the controller.'
                                          : 'The controller has not made any object yet.'}
                                </p>
                            </EmptyState>
                        {/if}
                    </div>
                    <div class="panel">
                        <div class="hd"><h2>Revision and endpoint</h2></div>
                        <div class="bd">
                            <dl class="kv sm" data-testid="deploy-revision">
                                <dt>Revision</dt>
                                <dd>
                                    {#if detail?.status?.revision}<code>{detail.status.revision}</code>{:else}<span
                                            class="t3">None yet</span
                                        >{/if}
                                </dd>
                                <dt>Endpoint</dt>
                                <dd>
                                    {#if detail?.status?.endpoint?.url}<code>{detail.status.endpoint.url}</code
                                        >{:else}<span class="t3">None</span>{/if}
                                </dd>
                            </dl>
                        </div>
                    </div>
                    <div class="panel">
                        <div class="hd"><h2>Caller rule to hand to an operator</h2></div>
                        <div class="bd">
                            <CodeViewer code={callerYaml} label="caller rule" copyLabel="Copy rule" />
                            <p class="sm t3 mt-2">Example for a webhook binding. The operator chooses the caller.</p>
                        </div>
                    </div>
                </div>
            </div>
        {/if}
    {/if}
</section>

{#if yamlOpen && detail}
    <SideSheet title="{name}.yaml" onclose={() => (yamlOpen = false)}>
        {#snippet headerExtra()}
            <Segmented
                label="Version"
                value={yamlView}
                options={[
                    { id: 'cluster', label: 'Cluster' },
                    { id: 'draft', label: 'Draft' },
                ]}
                onselect={(id) => (yamlView = id)}
            />
        {/snippet}
        {#if yamlView === 'cluster'}
            <CodeViewer code={detail.yaml} label="YAML" copyLabel="Copy YAML" />
        {:else}
            <CodeViewer code={draftYaml} label="YAML of the draft" copyLabel="Copy YAML" {changed} />
            <p class="sm t3">
                {changed.size
                    ? `${changed.size} ${changed.size === 1 ? 'line differs' : 'lines differ'} from the cluster (marked).`
                    : 'The draft matches the cluster.'}
            </p>
        {/if}
        <p class="sm t3">Read-only. To change this resource outside the form, use <code>kubectl apply</code>.</p>
    </SideSheet>
{/if}

{#if deleteOpen && name}
    <Dialog destructive onclose={() => (deleteOpen = false)} initial="[data-cancel]">
        {#snippet title()}Delete agent <span class="mono">{name}</span>?{/snippet}
        <p class="t2">
            This deletes the definition and everything the controller made for it: the runtime agent and its template,
            model config, harness and egress policy, and the gateway key. Running conversations stop. Memories saved by
            this agent stay in the memory database until they expire.
        </p>
        <div class="field">
            <label for="del-confirm">Type {name} to confirm</label>
            <input id="del-confirm" class="mono" bind:value={deleteText} autocomplete="off" spellcheck="false" />
        </div>
        {#snippet actions()}
            <Button onclick={() => (deleteOpen = false)} data-cancel="">Cancel</Button>
            <Button
                variant="danger"
                busy={deleteBusy}
                disabledReason={deleteText !== name ? `Type ${name} to enable this button.` : undefined}
                onclick={confirmDelete}>Delete agent</Button
            >
        {/snippet}
    </Dialog>
{/if}
