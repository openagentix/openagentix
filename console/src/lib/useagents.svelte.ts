// Reads GET /api/v1/agents once for a page. The read-only pages show which agents use a model, a profile or a skill from it.
import { api, describeError } from './api';
import type { Agent, AgentList } from './types';

export function useAgents() {
    let list = $state<AgentList | null>(null);
    let error = $state('');
    let loading = $state(true);

    async function load() {
        loading = true;
        try {
            list = await api.agents();
            error = '';
        } catch (e) {
            error = describeError('read', 'the agents', e);
        } finally {
            loading = false;
        }
    }

    return {
        get list() {
            return list;
        },
        get items(): Agent[] {
            return list?.items ?? [];
        },
        get error() {
            return error;
        },
        get loading() {
            return loading;
        },
        load,
    };
}
