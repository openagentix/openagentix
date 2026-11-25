import { render, screen } from '@testing-library/svelte';
import { describe, expect, it } from 'vitest';
import MetricsRow from './MetricsRow.svelte';

describe('MetricsRow', () => {
    it('renders nothing without a summary: no zero, no sample', () => {
        const { container } = render(MetricsRow, { summary: null });
        expect(container).not.toHaveTextContent(/Spend|Tokens|Turns/);
    });
    it('renders the three tiles from a summary', () => {
        render(MetricsRow, {
            summary: {
                window: '24h',
                spendUsd: 0.191,
                spendTodayUsd: 0.074,
                tokensIn: 2.04e6,
                tokensOut: 15100,
                requests: 63,
                byUser: [{ user: 'assistant', costUsd: 0.118, tokensIn: 1, tokensOut: 1, tokensCacheRead: 0 }],
                series: [0.01, 0.02],
                generatedAt: 'x',
            },
        });
        expect(screen.getByRole('group', { name: /Metrics/ })).toHaveTextContent('Spend today');
        expect(screen.getByText('63')).toBeInTheDocument();
        expect(screen.getByRole('img', { name: /Spend per step/ })).toBeInTheDocument();
        expect(screen.getByRole('list', { name: 'Spend per agent key' })).toHaveTextContent('assistant');
    });
});
