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
                spendToday: '$0.19',
                spendNote: 'gateway price catalog',
                tokensToday: '2.0M',
                tokensNote: 'in and out',
                turns24h: '63',
                turnsNote: 'last 24 h',
            },
        });
        expect(screen.getByRole('group', { name: /Metrics/ })).toHaveTextContent('Spend today');
        expect(screen.getByText('63')).toBeInTheDocument();
    });
});
