// @ts-check
const fs = require('node:fs');
const path = require('node:path');

// Address of the site. Today it is served by GitHub Pages under /openagentix/.
// To move to a custom domain, set DOCS_URL, DOCS_BASE_URL and DOCS_CNAME at build time
// (the docs workflow reads them from repository variables). See website/README.md.
const url = (process.env.DOCS_URL || 'https://openagentix.github.io').replace(/\/+$/, '');
let baseUrl = process.env.DOCS_BASE_URL || '/openagentix/';
if (!baseUrl.startsWith('/')) baseUrl = `/${baseUrl}`;
if (!baseUrl.endsWith('/')) baseUrl = `${baseUrl}/`;
const cname = (process.env.DOCS_CNAME || '').trim();

// Files that depend on the address are written at build time and are not committed.
const staticDir = path.join(__dirname, 'static');
if (cname) fs.writeFileSync(path.join(staticDir, 'CNAME'), `${cname}\n`);
else fs.rmSync(path.join(staticDir, 'CNAME'), {force: true});
fs.writeFileSync(
  path.join(staticDir, 'robots.txt'),
  `User-agent: *\nAllow: /\n\nSitemap: ${url}${baseUrl}sitemap.xml\n`,
);

// The roadmap and the contributing page live in docs/ next to other plugins' folders, so a docs
// plugin cannot take them in place. Copy them to a generated folder and point their links at the site.
const projectDir = path.join(__dirname, '.generated', 'project');
fs.rmSync(projectDir, {recursive: true, force: true});
fs.mkdirSync(path.join(projectDir, 'contributing'), {recursive: true});
const toSite = (text) =>
  text
    .replace(/\]\((?:\.\.\/)?decisions\/README\.md\)/g, '](/decisions/)')
    .replace(/\]\((?:\.\.\/)?decisions\/([0-9a-z-]+)\.md(#[^)]*)?\)/g, (_m, id, hash) => `](/decisions/${id.replace(/^[0-9]+-/, "")}${hash || ''})`)
    .replace(/\]\(\.\.\/roadmap\.md\)/g, '](/project/roadmap)')
    .replace(/\]\(\.\.\/diary\/([0-9A-Za-z/_-]+)\.md(#[^)]*)?\)/g, (_m, id, hash) => `](/${id}${hash || ''})`);
for (const f of ['roadmap.md', 'contributing/workflow.md']) {
  fs.writeFileSync(path.join(projectDir, f), toSite(fs.readFileSync(path.join(__dirname, '..', 'docs', f), 'utf8')));
}

const repo = 'https://github.com/openagentix/openagentix';
const description =
  'OpenAgentix is an open-source, Kubernetes-native control plane for AI agents: agent governance with a key and token budget per agent, MCP tool profiles, egress control, an A2A gate and an audit trail. Apache-2.0.';

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: 'OpenAgentix',
  tagline: 'The open-source control plane for running AI agents on Kubernetes under your rules',
  favicon: 'img/favicon.svg',
  url,
  baseUrl,
  organizationName: 'openagentix',
  projectName: 'openagentix',
  trailingSlash: false,
  onBrokenLinks: 'throw',
  onBrokenAnchors: 'throw',
  onDuplicateRoutes: 'throw',
  i18n: {defaultLocale: 'en', locales: ['en']},
  // Structured data for search engines: what the project is, its licence and its code.
  headTags: [
    {
      tagName: 'script',
      attributes: {type: 'application/ld+json'},
      innerHTML: JSON.stringify({
        '@context': 'https://schema.org',
        '@type': 'SoftwareSourceCode',
        name: 'OpenAgentix',
        description,
        url: `${url}${baseUrl}`,
        codeRepository: repo,
        license: 'https://www.apache.org/licenses/LICENSE-2.0',
        programmingLanguage: ['Go', 'TypeScript'],
        runtimePlatform: 'Kubernetes',
      }),
    },
  ],
  markdown: {
    format: 'detect',
    mermaid: true,
    hooks: {onBrokenMarkdownLinks: 'throw'},
  },
  themes: [
    '@docusaurus/theme-mermaid',
    [
      '@easyops-cn/docusaurus-search-local',
      {
        hashed: true,
        language: ['en'],
        indexDocs: true,
        indexBlog: false,
        indexPages: false,
        docsRouteBasePath: ['/', 'decisions', 'project'],
        highlightSearchTermsOnTargetPage: true,
        explicitSearchResultPath: true,
      },
    ],
  ],
  presets: [
    [
      'classic',
      {
        docs: {
          path: '../docs/diary',
          routeBasePath: '/',
          exclude: ['**/README.md'],
          sidebarPath: './sidebars.js',
          editUrl: `${repo}/tree/main/docs/diary/`,
          showLastUpdateTime: true,
        },
        blog: false,
        theme: {customCss: './src/css/custom.css'},
        sitemap: {changefreq: null, priority: null},
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
        editUrl: `${repo}/tree/main/docs/decisions/`,
        showLastUpdateTime: true,
      },
    ],
    [
      '@docusaurus/plugin-content-docs',
      {
        id: 'project',
        path: '.generated/project',
        routeBasePath: 'project',
        sidebarPath: './sidebars-project.js',
        editUrl: `${repo}/tree/main/docs/`,
        showLastUpdateTime: true,
      },
    ],
  ],
  themeConfig: {
    image: 'img/social-card.png',
    metadata: [
      {name: 'description', content: description},
      {name: 'keywords', content: 'AI agents on Kubernetes, agent governance, A2A protocol, MCP, MCP gateway, egress control, audit trail, token budgets, bring your own agent, platform engineering, open source'},
    ],
    colorMode: {defaultMode: 'light', respectPrefersColorScheme: true},
    navbar: {
      title: 'OpenAgentix',
      logo: {alt: 'OpenAgentix', src: 'img/logo.svg', srcDark: 'img/logo-dark.svg'},
      items: [
        {to: '/guide/why', label: 'Start here', position: 'left', activeBaseRegex: `^${baseUrl}(guide|$)`},
        {to: '/what-works', label: 'Features', position: 'left', activeBaseRegex: `^${baseUrl}(features|what-works)`},
        {type: 'docSidebar', sidebarId: 'decisions', docsPluginId: 'decisions', label: 'Decisions', position: 'left'},
        {to: '/project/roadmap', label: 'Roadmap', position: 'left'},
        {to: '/project/contributing/workflow', label: 'Contributing', position: 'left'},
        {to: '/timeline', label: 'Diary', position: 'left'},
        {type: 'search', position: 'right'},
        {href: repo, label: 'GitHub', position: 'right'},
      ],
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Documentation',
          items: [
            {label: 'Why OpenAgentix', to: '/guide/why'},
            {label: 'Quick start', to: '/guide/quick-start'},
            {label: 'What works', to: '/what-works'},
            {label: 'Decisions', to: '/decisions/'},
          ],
        },
        {
          title: 'Project',
          items: [
            {label: 'Repository', href: repo},
            {label: 'Issues', href: `${repo}/issues`},
            {label: 'Discussions', href: `${repo}/discussions`},
            {label: 'Your first contribution', to: '/guide/first-contribution'},
            {label: 'Good first issues', href: `${repo}/labels/good%20first%20issue`},
            {label: 'Adopters', href: `${repo}/blob/main/ADOPTERS.md`},
          ],
        },
        {
          title: 'Policies',
          items: [
            {label: 'Security policy', href: `${repo}/blob/main/SECURITY.md`},
            {label: 'Licence (Apache-2.0)', href: `${repo}/blob/main/LICENSE`},
            {label: 'Code of conduct', href: `${repo}/blob/main/CODE_OF_CONDUCT.md`},
          ],
        },
      ],
      copyright: 'OpenAgentix is open source under the Apache-2.0 licence.',
    },
    mermaid: {theme: {light: 'neutral', dark: 'dark'}},
  },
};
module.exports = config;
