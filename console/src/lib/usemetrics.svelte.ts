// Reads GET /api/v1/metrics/summary when the platform says a metrics store is configured. A failure is one calm sentence,
// never a number.
import { api, ApiError } from './api';
import type { MetricsSummary } from './metrics';

export function useMetrics() {
    let summary = $state<MetricsSummary | null>(null);
    let error = $state('');
    let loading = $state(false);

    async function load(window: '24h' | '7d' = '24h') {
        loading = true;
        try {
            summary = await api.metrics(window);
            error = '';
        } catch (e) {
            summary = null;
            error =
                e instanceof ApiError && e.code === 'metrics_unavailable'
                    ? e.message
                    : 'Metrics are not available: the console could not read them.';
        } finally {
            loading = false;
        }
    }

    return {
        get summary() {
            return summary;
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
