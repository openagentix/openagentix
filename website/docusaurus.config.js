// @ts-check
const config = {
  title: 'OpenAgentix',
  tagline: 'The open-source control plane for running AI agents on Kubernetes under your rules',
  favicon: 'img/favicon.svg',
  url: 'https://openagentix.github.io',
  baseUrl: '/openagentix/',
  organizationName: 'openagentix',
  projectName: 'openagentix',
  trailingSlash: false,
  onBrokenLinks: 'throw',
  i18n: {defaultLocale: 'en', locales: ['en']},
  markdown: {
    format: 'detect',
    mermaid: true,
    hooks: {onBrokenMarkdownLinks: 'throw'},
  },
  themes: ['@docusaurus/theme-mermaid'],
  presets: [
    [
      'classic',
      {
        docs: {
          path: '../docs/diary',
          routeBasePath: '/',
          exclude: ['**/README.md'],
          sidebarPath: './sidebars.js',
          editUrl: 'https://github.com/openagentix/openagentix/tree/main/docs/diary/',
        },
        blog: false,
        theme: {},
      },
    ],
  ],
  plugins: [
    [
      '@docusaurus/plugin-content-docs',
      {
        id: 'decisions',
        path: '../docs/decisions',
        routeBasePath: 'decisions',
        sidebarPath: './sidebars-decisions.js',
        editUrl: 'https://github.com/openagentix/openagentix/tree/main/docs/decisions/',
      },
    ],
  ],
  themeConfig: {
    metadata: [
      {
        name: 'description',
        content:
          'OpenAgentix is an open-source control plane for running AI agents on Kubernetes: a key and budget per agent, approved tools, closed egress, checked callers and an audit record. Apache-2.0.',
      },
    ],
    colorMode: {defaultMode: 'light', respectPrefersColorScheme: true},
    navbar: {
      title: 'OpenAgentix',
      items: [
        {to: '/guide/why', label: 'Start here', position: 'left'},
        {to: '/', label: 'Diary', position: 'left', activeBaseRegex: '^/openagentix/(?!decisions|guide)'},
        {type: 'docSidebar', sidebarId: 'decisions', docsPluginId: 'decisions', label: 'Decisions', position: 'left'},
        {href: 'https://github.com/openagentix/openagentix', label: 'GitHub', position: 'right'},
      ],
    },
    footer: {style: 'dark', copyright: 'Apache-2.0'},
  },
};
module.exports = config;
