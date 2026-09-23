import Foundation
import OdeteBundler
import OdeteNpm
import Testing

/// O modelo "blog" do `create-astro`, com os arquivos que ele escreve: content collections
/// (`src/content.config.ts` com `glob()` e schema do zod), `getCollection`, `render`, a rota
/// `[...slug]` com `getStaticPaths`, `astro:assets` (`<Image>` e `<Font>`), post em MDX com
/// componente e o endpoint `rss.xml.js` com `@astrojs/rss`.
///
/// Instala só o que o código roda aqui (zod e @astrojs/rss): as integrações do config são
/// plugins do Vite. Sem rede, cala.
struct AstroBlogTests {
    static let arquivos: [String: String] = [
        "astro.config.mjs": ###"""
// @ts-check

import mdx from '@astrojs/mdx';
import sitemap from '@astrojs/sitemap';
import { defineConfig, fontProviders } from 'astro/config';

// https://astro.build/config
export default defineConfig({
	site: 'https://example.com',
	integrations: [mdx(), sitemap()],
	fonts: [
		{
			provider: fontProviders.local(),
			name: 'Atkinson',
			cssVariable: '--font-atkinson',
			fallbacks: ['sans-serif'],
			options: {
				variants: [
					{
						src: ['./src/assets/fonts/atkinson-regular.woff'],
						weight: 400,
						style: 'normal',
						display: 'swap',
					},
					{
						src: ['./src/assets/fonts/atkinson-bold.woff'],
						weight: 700,
						style: 'normal',
						display: 'swap',
					},
				],
			},
		},
	],
});
"""###,
        "src/content.config.ts": ###"""
import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';
import { z } from 'astro/zod';

const blog = defineCollection({
	// Load Markdown and MDX files in the `src/content/blog/` directory.
	loader: glob({ base: './src/content/blog', pattern: '**/*.{md,mdx}' }),
	// Type-check frontmatter using a schema
	schema: ({ image }) =>
		z.object({
			title: z.string(),
			description: z.string(),
			// Transform string to Date object
			pubDate: z.coerce.date(),
			updatedDate: z.coerce.date().optional(),
			heroImage: z.optional(image()),
		}),
});

export const collections = { blog };
"""###,
        "src/consts.ts": ###"""
// Place any global data in this file.
// You can import this data from anywhere in your site by using the `import` keyword.

export const SITE_TITLE = 'Astro Blog';
export const SITE_DESCRIPTION = 'Welcome to my website!';
"""###,
        "src/styles/global.css": ###"""
/*
  The CSS in this style tag is based off of Bear Blog's default CSS.
  https://github.com/HermanMartinus/bearblog/blob/297026a877bc2ab2b3bdfbd6b9f7961c350917dd/templates/styles/blog/default.css
  License MIT: https://github.com/HermanMartinus/bearblog/blob/master/LICENSE.md
 */

:root {
	--accent: #2337ff;
	--accent-dark: #000d8a;
	--black: 15, 18, 25;
	--gray: 96, 115, 159;
	--gray-light: 229, 233, 240;
	--gray-dark: 34, 41, 57;
	--gray-gradient: rgba(var(--gray-light), 50%), #fff;
	--box-shadow:
		0 2px 6px rgba(var(--gray), 25%), 0 8px 24px rgba(var(--gray), 33%),
		0 16px 32px rgba(var(--gray), 33%);
}
body {
	font-family: var(--font-atkinson);
	margin: 0;
	padding: 0;
	text-align: left;
	background: linear-gradient(var(--gray-gradient)) no-repeat;
	background-size: 100% 600px;
	word-wrap: break-word;
	overflow-wrap: break-word;
	color: rgb(var(--gray-dark));
	font-size: 20px;
	line-height: 1.7;
}
main {
	width: 720px;
	max-width: calc(100% - 2em);
	margin: auto;
	padding: 3em 1em;
}
h1,
h2,
h3,
h4,
h5,
h6 {
	margin: 0 0 0.5rem 0;
	color: rgb(var(--black));
	line-height: 1.2;
}
h1 {
	font-size: 3.052em;
}
h2 {
	font-size: 2.441em;
}
h3 {
	font-size: 1.953em;
}
h4 {
	font-size: 1.563em;
}
h5 {
	font-size: 1.25em;
}
strong,
b {
	font-weight: 700;
}
a {
	color: var(--accent);
}
a:hover {
	color: var(--accent);
}
p {
	margin-bottom: 1em;
}
.prose p {
	margin-bottom: 2em;
}
textarea {
	width: 100%;
	font-size: 16px;
}
input {
	font-size: 16px;
}
table {
	width: 100%;
}
img {
	max-width: 100%;
	height: auto;
	border-radius: 8px;
}
code {
	padding: 2px 5px;
	background-color: rgb(var(--gray-light));
	border-radius: 2px;
}
pre {
	padding: 1.5em;
	border-radius: 8px;
}
pre > code {
	all: unset;
}
blockquote {
	border-left: 4px solid var(--accent);
	padding: 0 0 0 20px;
	margin: 0;
	font-size: 1.333em;
}
hr {
	border: none;
	border-top: 1px solid rgb(var(--gray-light));
}
@media (max-width: 720px) {
	body {
		font-size: 18px;
	}
	main {
		padding: 1em;
	}
}

.sr-only {
	border: 0;
	padding: 0;
	margin: 0;
	position: absolute !important;
	height: 1px;
	width: 1px;
	overflow: hidden;
	/* IE6, IE7 - a 0 height clip, off to the bottom right of the visible 1px box */
	clip: rect(1px 1px 1px 1px);
	/* maybe deprecated but we need to support legacy browsers */
	clip: rect(1px, 1px, 1px, 1px);
	/* modern browsers, clip-path works inwards from each corner */
	clip-path: inset(50%);
	/* added line to stop words getting smushed together (as they go onto separate lines and some screen readers do not understand line feeds as a space */
	white-space: nowrap;
}
"""###,
        "src/components/BaseHead.astro": ###"""
---
// Import the global.css file here so that it is included on
// all pages through the use of the <BaseHead /> component.
import '../styles/global.css';
import type { ImageMetadata } from 'astro';
import FallbackImage from '../assets/blog-placeholder-1.jpg';
import { SITE_TITLE } from '../consts';
import { Font } from 'astro:assets';

interface Props {
	title: string;
	description: string;
	image?: ImageMetadata;
}

const canonicalURL = new URL(Astro.url.pathname, Astro.site);

const { title, description, image = FallbackImage } = Astro.props;
---

<!-- Global Metadata -->
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<link rel="icon" type="image/svg+xml" href="/favicon.svg" />
<link rel="icon" href="/favicon.ico" />
<link rel="sitemap" href="/sitemap-index.xml" />
<link
	rel="alternate"
	type="application/rss+xml"
	title={SITE_TITLE}
	href={new URL('rss.xml', Astro.site)}
/>
<meta name="generator" content={Astro.generator} />

<Font cssVariable="--font-atkinson" preload />

<!-- Canonical URL -->
<link rel="canonical" href={canonicalURL} />

<!-- Primary Meta Tags -->
<title>{title}</title>
<meta name="description" content={description} />

<!-- Open Graph / Facebook -->
<meta property="og:type" content="website" />
<meta property="og:url" content={Astro.url} />
<meta property="og:title" content={title} />
<meta property="og:description" content={description} />
<meta property="og:image" content={new URL(image.src, Astro.url)} />

<!-- Twitter -->
<meta name="twitter:card" content="summary_large_image" />
"""###,
        "src/components/Header.astro": ###"""
---
import { SITE_TITLE } from '../consts';
import HeaderLink from './HeaderLink.astro';
---

<header>
	<nav>
		<h2><a href="/">{SITE_TITLE}</a></h2>
		<div class="internal-links">
			<HeaderLink href="/">Home</HeaderLink>
			<HeaderLink href="/blog">Blog</HeaderLink>
			<HeaderLink href="/about">About</HeaderLink>
		</div>
		<div class="social-links">
			<a href="https://m.webtoo.ls/@astro" target="_blank">
				<span class="sr-only">Follow Astro on Mastodon</span>
				<svg viewBox="0 0 16 16" aria-hidden="true" width="32" height="32"
					><path
						fill="currentColor"
						d="M11.19 12.195c2.016-.24 3.77-1.475 3.99-2.603.348-1.778.32-4.339.32-4.339 0-3.47-2.286-4.488-2.286-4.488C12.062.238 10.083.017 8.027 0h-.05C5.92.017 3.942.238 2.79.765c0 0-2.285 1.017-2.285 4.488l-.002.662c-.004.64-.007 1.35.011 2.091.083 3.394.626 6.74 3.78 7.57 1.454.383 2.703.463 3.709.408 1.823-.1 2.847-.647 2.847-.647l-.06-1.317s-1.303.41-2.767.36c-1.45-.05-2.98-.156-3.215-1.928a3.614 3.614 0 0 1-.033-.496s1.424.346 3.228.428c1.103.05 2.137-.064 3.188-.189zm1.613-2.47H11.13v-4.08c0-.859-.364-1.295-1.091-1.295-.804 0-1.207.517-1.207 1.541v2.233H7.168V5.89c0-1.024-.403-1.541-1.207-1.541-.727 0-1.091.436-1.091 1.296v4.079H3.197V5.522c0-.859.22-1.541.66-2.046.456-.505 1.052-.764 1.793-.764.856 0 1.504.328 1.933.983L8 4.39l.417-.695c.429-.655 1.077-.983 1.934-.983.74 0 1.336.259 1.791.764.442.505.661 1.187.661 2.046v4.203z"
					></path></svg
				>
			</a>
			<a href="https://twitter.com/astrodotbuild" target="_blank">
				<span class="sr-only">Follow Astro on Twitter</span>
				<svg viewBox="0 0 16 16" aria-hidden="true" width="32" height="32"
					><path
						fill="currentColor"
						d="M5.026 15c6.038 0 9.341-5.003 9.341-9.334 0-.14 0-.282-.006-.422A6.685 6.685 0 0 0 16 3.542a6.658 6.658 0 0 1-1.889.518 3.301 3.301 0 0 0 1.447-1.817 6.533 6.533 0 0 1-2.087.793A3.286 3.286 0 0 0 7.875 6.03a9.325 9.325 0 0 1-6.767-3.429 3.289 3.289 0 0 0 1.018 4.382A3.323 3.323 0 0 1 .64 6.575v.045a3.288 3.288 0 0 0 2.632 3.218 3.203 3.203 0 0 1-.865.115 3.23 3.23 0 0 1-.614-.057 3.283 3.283 0 0 0 3.067 2.277A6.588 6.588 0 0 1 .78 13.58a6.32 6.32 0 0 1-.78-.045A9.344 9.344 0 0 0 5.026 15z"
					></path></svg
				>
			</a>
			<a href="https://github.com/withastro/astro" target="_blank">
				<span class="sr-only">Go to Astro's GitHub repo</span>
				<svg viewBox="0 0 16 16" aria-hidden="true" width="32" height="32"
					><path
						fill="currentColor"
						d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.012 8.012 0 0 0 16 8c0-4.42-3.58-8-8-8z"
					></path></svg
				>
			</a>
		</div>
	</nav>
</header>
<style>
	header {
		margin: 0;
		padding: 0 1em;
		background: white;
		box-shadow: 0 2px 8px rgba(var(--black), 5%);
	}
	h2 {
		margin: 0;
		font-size: 1em;
	}

	h2 a,
	h2 a.active {
		text-decoration: none;
	}
	nav {
		display: flex;
		align-items: center;
		justify-content: space-between;
	}
	nav a {
		padding: 1em 0.5em;
		color: var(--black);
		border-bottom: 4px solid transparent;
		text-decoration: none;
	}
	nav a.active {
		text-decoration: none;
		border-bottom-color: var(--accent);
	}
	.social-links,
	.social-links a {
		display: flex;
	}
	@media (max-width: 720px) {
		.social-links {
			display: none;
		}
	}
</style>
"""###,
        "src/components/HeaderLink.astro": ###"""
---
import type { HTMLAttributes } from 'astro/types';

type Props = HTMLAttributes<'a'>;

const { href, class: className, ...props } = Astro.props;
const pathname = Astro.url.pathname.replace(import.meta.env.BASE_URL, '');
const subpath = pathname.match(/[^\/]+/g);
const isActive = href === pathname || href === '/' + (subpath?.[0] || '');
---

<a href={href} class:list={[className, { active: isActive }]} {...props}>
	<slot />
</a>
<style>
	a {
		display: inline-block;
		text-decoration: none;
	}
	a.active {
		font-weight: bolder;
		text-decoration: underline;
	}
</style>
"""###,
        "src/components/Footer.astro": ###"""
---
const today = new Date();
---

<footer>
	&copy; {today.getFullYear()} Your name here. All rights reserved.
	<div class="social-links">
		<a href="https://m.webtoo.ls/@astro" target="_blank">
			<span class="sr-only">Follow Astro on Mastodon</span>
			<svg
				viewBox="0 0 16 16"
				aria-hidden="true"
				width="32"
				height="32"
				astro-icon="social/mastodon"
				><path
					fill="currentColor"
					d="M11.19 12.195c2.016-.24 3.77-1.475 3.99-2.603.348-1.778.32-4.339.32-4.339 0-3.47-2.286-4.488-2.286-4.488C12.062.238 10.083.017 8.027 0h-.05C5.92.017 3.942.238 2.79.765c0 0-2.285 1.017-2.285 4.488l-.002.662c-.004.64-.007 1.35.011 2.091.083 3.394.626 6.74 3.78 7.57 1.454.383 2.703.463 3.709.408 1.823-.1 2.847-.647 2.847-.647l-.06-1.317s-1.303.41-2.767.36c-1.45-.05-2.98-.156-3.215-1.928a3.614 3.614 0 0 1-.033-.496s1.424.346 3.228.428c1.103.05 2.137-.064 3.188-.189zm1.613-2.47H11.13v-4.08c0-.859-.364-1.295-1.091-1.295-.804 0-1.207.517-1.207 1.541v2.233H7.168V5.89c0-1.024-.403-1.541-1.207-1.541-.727 0-1.091.436-1.091 1.296v4.079H3.197V5.522c0-.859.22-1.541.66-2.046.456-.505 1.052-.764 1.793-.764.856 0 1.504.328 1.933.983L8 4.39l.417-.695c.429-.655 1.077-.983 1.934-.983.74 0 1.336.259 1.791.764.442.505.661 1.187.661 2.046v4.203z"
				></path></svg
			>
		</a>
		<a href="https://twitter.com/astrodotbuild" target="_blank">
			<span class="sr-only">Follow Astro on Twitter</span>
			<svg viewBox="0 0 16 16" aria-hidden="true" width="32" height="32" astro-icon="social/twitter"
				><path
					fill="currentColor"
					d="M5.026 15c6.038 0 9.341-5.003 9.341-9.334 0-.14 0-.282-.006-.422A6.685 6.685 0 0 0 16 3.542a6.658 6.658 0 0 1-1.889.518 3.301 3.301 0 0 0 1.447-1.817 6.533 6.533 0 0 1-2.087.793A3.286 3.286 0 0 0 7.875 6.03a9.325 9.325 0 0 1-6.767-3.429 3.289 3.289 0 0 0 1.018 4.382A3.323 3.323 0 0 1 .64 6.575v.045a3.288 3.288 0 0 0 2.632 3.218 3.203 3.203 0 0 1-.865.115 3.23 3.23 0 0 1-.614-.057 3.283 3.283 0 0 0 3.067 2.277A6.588 6.588 0 0 1 .78 13.58a6.32 6.32 0 0 1-.78-.045A9.344 9.344 0 0 0 5.026 15z"
				></path></svg
			>
		</a>
		<a href="https://github.com/withastro/astro" target="_blank">
			<span class="sr-only">Go to Astro's GitHub repo</span>
			<svg viewBox="0 0 16 16" aria-hidden="true" width="32" height="32" astro-icon="social/github"
				><path
					fill="currentColor"
					d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.012 8.012 0 0 0 16 8c0-4.42-3.58-8-8-8z"
				></path></svg
			>
		</a>
	</div>
</footer>
<style>
	footer {
		padding: 2em 1em 6em 1em;
		background: linear-gradient(var(--gray-gradient)) no-repeat;
		color: rgb(var(--gray));
		text-align: center;
	}
	.social-links {
		display: flex;
		justify-content: center;
		gap: 1em;
		margin-top: 1em;
	}
	.social-links a {
		text-decoration: none;
		color: rgb(var(--gray));
	}
	.social-links a:hover {
		color: rgb(var(--gray-dark));
	}
</style>
"""###,
        "src/components/FormattedDate.astro": ###"""
---
interface Props {
	date: Date;
}

const { date } = Astro.props;
---

<time datetime={date.toISOString()}>
	{
		date.toLocaleDateString('en-us', {
			year: 'numeric',
			month: 'short',
			day: 'numeric',
		})
	}
</time>
"""###,
        "src/layouts/BlogPost.astro": ###"""
---
import { Image } from 'astro:assets';
import type { CollectionEntry } from 'astro:content';
import BaseHead from '../components/BaseHead.astro';
import Footer from '../components/Footer.astro';
import FormattedDate from '../components/FormattedDate.astro';
import Header from '../components/Header.astro';

type Props = CollectionEntry<'blog'>['data'];

const { title, description, pubDate, updatedDate, heroImage } = Astro.props;
---

<html lang="en">
	<head>
		<BaseHead title={title} description={description} />
		<style>
			main {
				width: calc(100% - 2em);
				max-width: 100%;
				margin: 0;
			}
			.hero-image {
				width: 100%;
			}
			.hero-image img {
				display: block;
				margin: 0 auto;
				border-radius: 12px;
				box-shadow: var(--box-shadow);
			}
			.prose {
				width: 720px;
				max-width: calc(100% - 2em);
				margin: auto;
				padding: 1em;
				color: rgb(var(--gray-dark));
			}
			.title {
				margin-bottom: 1em;
				padding: 1em 0;
				text-align: center;
				line-height: 1;
			}
			.title h1 {
				margin: 0 0 0.5em 0;
			}
			.date {
				margin-bottom: 0.5em;
				color: rgb(var(--gray));
			}
			.last-updated-on {
				font-style: italic;
			}
		</style>
	</head>

	<body>
		<Header />
		<main>
			<article>
				<div class="hero-image">
					{heroImage && <Image width={1020} height={510} src={heroImage} alt="" />}
				</div>
				<div class="prose">
					<div class="title">
						<div class="date">
							<FormattedDate date={pubDate} />
							{
								updatedDate && (
									<div class="last-updated-on">
										Last updated on <FormattedDate date={updatedDate} />
									</div>
								)
							}
						</div>
						<h1>{title}</h1>
						<hr />
					</div>
					<slot />
				</div>
			</article>
		</main>
		<Footer />
	</body>
</html>
"""###,
        "src/pages/index.astro": ###"""
---
import BaseHead from '../components/BaseHead.astro';
import Footer from '../components/Footer.astro';
import Header from '../components/Header.astro';
import { SITE_DESCRIPTION, SITE_TITLE } from '../consts';
---

<!doctype html>
<html lang="en">
	<head>
		<BaseHead title={SITE_TITLE} description={SITE_DESCRIPTION} />
	</head>
	<body>
		<Header />
		<main>
			<h1>🧑‍🚀 Hello, Astronaut!</h1>
			<p>
				Welcome to the official <a href="https://astro.build/">Astro</a> blog starter template. This template
				serves as a lightweight, minimally-styled starting point for anyone looking to build a personal
				website, blog, or portfolio with Astro.
			</p>
			<p>
				This template comes with a few integrations already configured in your{' '}
				<code>astro.config.mjs</code> file. You can customize your setup with{' '}
				<a href="https://astro.build/integrations">Astro Integrations</a> to add tools like Tailwind,
				React, or Vue to your project.
			</p>
			<p>Here are a few ideas on how to get started with the template:</p>
			<ul>
				<li>Edit this page in <code>src/pages/index.astro</code></li>
				<li>Edit the site header items in <code>src/components/Header.astro</code></li>
				<li>Add your name to the footer in <code>src/components/Footer.astro</code></li>
				<li>Check out the included blog posts in <code>src/content/blog/</code></li>
				<li>Customize the blog post page layout in <code>src/layouts/BlogPost.astro</code></li>
			</ul>
			<p>
				Have fun! If you get stuck, remember to{' '}
				<a href="https://docs.astro.build/">read the docs</a>{' '}
				or <a href="https://astro.build/chat">join us on Discord</a> to ask questions.
			</p>
			<p>
				Looking for a blog template with a bit more personality? Check out{' '}
				<a href="https://github.com/Charca/astro-blog-template">astro-blog-template</a>{' '}
				by <a href="https://twitter.com/Charca">Maxi Ferreira</a>.
			</p>
		</main>
		<Footer />
	</body>
</html>
"""###,
        "src/pages/about.astro": ###"""
---
import AboutHeroImage from '../assets/blog-placeholder-about.jpg';
import Layout from '../layouts/BlogPost.astro';
---

<Layout
	title="About Me"
	description="Lorem ipsum dolor sit amet"
	pubDate={new Date('August 08 2021')}
	heroImage={AboutHeroImage}
>
	<p>
		Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut
		labore et dolore magna aliqua. Vitae ultricies leo integer malesuada nunc vel risus commodo
		viverra. Adipiscing enim eu turpis egestas pretium. Euismod elementum nisi quis eleifend quam
		adipiscing. In hac habitasse platea dictumst vestibulum. Sagittis purus sit amet volutpat. Netus
		et malesuada fames ac turpis egestas. Eget magna fermentum iaculis eu non diam phasellus
		vestibulum lorem. Varius sit amet mattis vulputate enim. Habitasse platea dictumst quisque
		sagittis. Integer quis auctor elit sed vulputate mi. Dictumst quisque sagittis purus sit amet.
	</p>

	<p>
		Morbi tristique senectus et netus. Id semper risus in hendrerit gravida rutrum quisque non
		tellus. Habitasse platea dictumst quisque sagittis purus sit amet. Tellus molestie nunc non
		blandit massa. Cursus vitae congue mauris rhoncus. Accumsan tortor posuere ac ut. Fringilla urna
		porttitor rhoncus dolor. Elit ullamcorper dignissim cras tincidunt lobortis. In cursus turpis
		massa tincidunt dui ut ornare lectus. Integer feugiat scelerisque varius morbi enim nunc.
		Bibendum neque egestas congue quisque egestas diam. Cras ornare arcu dui vivamus arcu felis
		bibendum. Dignissim suspendisse in est ante in nibh mauris. Sed tempus urna et pharetra pharetra
		massa massa ultricies mi.
	</p>

	<p>
		Mollis nunc sed id semper risus in. Convallis a cras semper auctor neque. Diam sit amet nisl
		suscipit. Lacus viverra vitae congue eu consequat ac felis donec. Egestas integer eget aliquet
		nibh praesent tristique magna sit amet. Eget magna fermentum iaculis eu non diam. In vitae
		turpis massa sed elementum. Tristique et egestas quis ipsum suspendisse ultrices. Eget lorem
		dolor sed viverra ipsum. Vel turpis nunc eget lorem dolor sed viverra. Posuere ac ut consequat
		semper viverra nam. Laoreet suspendisse interdum consectetur libero id faucibus. Diam phasellus
		vestibulum lorem sed risus ultricies tristique. Rhoncus dolor purus non enim praesent elementum
		facilisis. Ultrices tincidunt arcu non sodales neque. Tempus egestas sed sed risus pretium quam
		vulputate. Viverra suspendisse potenti nullam ac tortor vitae purus faucibus ornare. Fringilla
		urna porttitor rhoncus dolor purus non. Amet dictum sit amet justo donec enim.
	</p>

	<p>
		Mattis ullamcorper velit sed ullamcorper morbi tincidunt. Tortor posuere ac ut consequat semper
		viverra. Tellus mauris a diam maecenas sed enim ut sem viverra. Venenatis urna cursus eget nunc
		scelerisque viverra mauris in. Arcu ac tortor dignissim convallis aenean et tortor at. Curabitur
		gravida arcu ac tortor dignissim convallis aenean et tortor. Egestas tellus rutrum tellus
		pellentesque eu. Fusce ut placerat orci nulla pellentesque dignissim enim sit amet. Ut enim
		blandit volutpat maecenas volutpat blandit aliquam etiam. Id donec ultrices tincidunt arcu. Id
		cursus metus aliquam eleifend mi.
	</p>

	<p>
		Tempus quam pellentesque nec nam aliquam sem. Risus at ultrices mi tempus imperdiet. Id porta
		nibh venenatis cras sed felis eget velit. Ipsum a arcu cursus vitae. Facilisis magna etiam
		tempor orci eu lobortis elementum. Tincidunt dui ut ornare lectus sit. Quisque non tellus orci
		ac. Blandit libero volutpat sed cras. Nec tincidunt praesent semper feugiat nibh sed pulvinar
		proin gravida. Egestas integer eget aliquet nibh praesent tristique magna.
	</p>
</Layout>
"""###,
        "src/pages/blog/index.astro": ###"""
---
import { Image } from 'astro:assets';
import { getCollection } from 'astro:content';
import BaseHead from '../../components/BaseHead.astro';
import Footer from '../../components/Footer.astro';
import FormattedDate from '../../components/FormattedDate.astro';
import Header from '../../components/Header.astro';
import { SITE_DESCRIPTION, SITE_TITLE } from '../../consts';

const posts = (await getCollection('blog')).sort(
	(a, b) => b.data.pubDate.valueOf() - a.data.pubDate.valueOf(),
);
---

<!doctype html>
<html lang="en">
	<head>
		<BaseHead title={SITE_TITLE} description={SITE_DESCRIPTION} />
		<style>
			main {
				width: 960px;
			}
			ul {
				display: flex;
				flex-wrap: wrap;
				gap: 2rem;
				list-style-type: none;
				margin: 0;
				padding: 0;
			}
			ul li {
				width: calc(50% - 1rem);
			}
			ul li * {
				text-decoration: none;
				transition: 0.2s ease;
			}
			ul li:first-child {
				width: 100%;
				margin-bottom: 1rem;
				text-align: center;
			}
			ul li:first-child img {
				width: 100%;
			}
			ul li:first-child .title {
				font-size: 2.369rem;
			}
			ul li img {
				margin-bottom: 0.5rem;
				border-radius: 12px;
			}
			ul li a {
				display: block;
			}
			.title {
				margin: 0;
				color: rgb(var(--black));
				line-height: 1;
			}
			.date {
				margin: 0;
				color: rgb(var(--gray));
			}
			ul li a:hover h4,
			ul li a:hover .date {
				color: rgb(var(--accent));
			}
			ul a:hover img {
				box-shadow: var(--box-shadow);
			}
			@media (max-width: 720px) {
				ul {
					gap: 0.5em;
				}
				ul li {
					width: 100%;
					text-align: center;
				}
				ul li:first-child {
					margin-bottom: 0;
				}
				ul li:first-child .title {
					font-size: 1.563em;
				}
			}
		</style>
	</head>
	<body>
		<Header />
		<main>
			<section>
				<ul>
					{
						posts.map((post) => (
							<li>
								<a href={`/blog/${post.id}/`}>
									{post.data.heroImage && (
										<Image width={720} height={360} src={post.data.heroImage} alt="" />
									)}
									<h4 class="title">{post.data.title}</h4>
									<p class="date">
										<FormattedDate date={post.data.pubDate} />
									</p>
								</a>
							</li>
						))
					}
				</ul>
			</section>
		</main>
		<Footer />
	</body>
</html>
"""###,
        "src/pages/blog/[...slug].astro": ###"""
---
import { type CollectionEntry, getCollection, render } from 'astro:content';
import BlogPost from '../../layouts/BlogPost.astro';

export async function getStaticPaths() {
	const posts = await getCollection('blog');
	return posts.map((post) => ({
		params: { slug: post.id },
		props: post,
	}));
}
type Props = CollectionEntry<'blog'>;

const post = Astro.props;
const { Content } = await render(post);
---

<BlogPost {...post.data}>
	<Content />
</BlogPost>
"""###,
        "src/pages/rss.xml.js": ###"""
import { getCollection } from 'astro:content';
import rss from '@astrojs/rss';
import { SITE_DESCRIPTION, SITE_TITLE } from '../consts';

export async function GET(context) {
	const posts = await getCollection('blog');
	return rss({
		title: SITE_TITLE,
		description: SITE_DESCRIPTION,
		site: context.site,
		items: posts.map((post) => ({
			...post.data,
			link: `/blog/${post.id}/`,
		})),
	});
}
"""###,
        "src/content/blog/first-post.md": ###"""
---
title: 'First post'
description: 'Lorem ipsum dolor sit amet'
pubDate: 'Jul 08 2022'
heroImage: '../../assets/blog-placeholder-3.jpg'
---

Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Vitae ultricies leo integer malesuada nunc vel risus commodo viverra. Adipiscing enim eu turpis egestas pretium. Euismod elementum nisi quis eleifend quam adipiscing. In hac habitasse platea dictumst vestibulum. Sagittis purus sit amet volutpat. Netus et malesuada fames ac turpis egestas. Eget magna fermentum iaculis eu non diam phasellus vestibulum lorem. Varius sit amet mattis vulputate enim. Habitasse platea dictumst quisque sagittis. Integer quis auctor elit sed vulputate mi. Dictumst quisque sagittis purus sit amet.

Morbi tristique senectus et netus. Id semper risus in hendrerit gravida rutrum quisque non tellus. Habitasse platea dictumst quisque sagittis purus sit amet. Tellus molestie nunc non blandit massa. Cursus vitae congue mauris rhoncus. Accumsan tortor posuere ac ut. Fringilla urna porttitor rhoncus dolor. Elit ullamcorper dignissim cras tincidunt lobortis. In cursus turpis massa tincidunt dui ut ornare lectus. Integer feugiat scelerisque varius morbi enim nunc. Bibendum neque egestas congue quisque egestas diam. Cras ornare arcu dui vivamus arcu felis bibendum. Dignissim suspendisse in est ante in nibh mauris. Sed tempus urna et pharetra pharetra massa massa ultricies mi.

Mollis nunc sed id semper risus in. Convallis a cras semper auctor neque. Diam sit amet nisl suscipit. Lacus viverra vitae congue eu consequat ac felis donec. Egestas integer eget aliquet nibh praesent tristique magna sit amet. Eget magna fermentum iaculis eu non diam. In vitae turpis massa sed elementum. Tristique et egestas quis ipsum suspendisse ultrices. Eget lorem dolor sed viverra ipsum. Vel turpis nunc eget lorem dolor sed viverra. Posuere ac ut consequat semper viverra nam. Laoreet suspendisse interdum consectetur libero id faucibus. Diam phasellus vestibulum lorem sed risus ultricies tristique. Rhoncus dolor purus non enim praesent elementum facilisis. Ultrices tincidunt arcu non sodales neque. Tempus egestas sed sed risus pretium quam vulputate. Viverra suspendisse potenti nullam ac tortor vitae purus faucibus ornare. Fringilla urna porttitor rhoncus dolor purus non. Amet dictum sit amet justo donec enim.

Mattis ullamcorper velit sed ullamcorper morbi tincidunt. Tortor posuere ac ut consequat semper viverra. Tellus mauris a diam maecenas sed enim ut sem viverra. Venenatis urna cursus eget nunc scelerisque viverra mauris in. Arcu ac tortor dignissim convallis aenean et tortor at. Curabitur gravida arcu ac tortor dignissim convallis aenean et tortor. Egestas tellus rutrum tellus pellentesque eu. Fusce ut placerat orci nulla pellentesque dignissim enim sit amet. Ut enim blandit volutpat maecenas volutpat blandit aliquam etiam. Id donec ultrices tincidunt arcu. Id cursus metus aliquam eleifend mi.

Tempus quam pellentesque nec nam aliquam sem. Risus at ultrices mi tempus imperdiet. Id porta nibh venenatis cras sed felis eget velit. Ipsum a arcu cursus vitae. Facilisis magna etiam tempor orci eu lobortis elementum. Tincidunt dui ut ornare lectus sit. Quisque non tellus orci ac. Blandit libero volutpat sed cras. Nec tincidunt praesent semper feugiat nibh sed pulvinar proin gravida. Egestas integer eget aliquet nibh praesent tristique magna.
"""###,
        "src/content/blog/markdown-style-guide.md": ###"""
---
title: 'Markdown Style Guide'
description: 'Here is a sample of some basic Markdown syntax that can be used when writing Markdown content in Astro.'
pubDate: 'Jun 19 2024'
heroImage: '../../assets/blog-placeholder-1.jpg'
---

Here is a sample of some basic Markdown syntax that can be used when writing Markdown content in Astro.

## Headings

The following HTML `<h1>`—`<h6>` elements represent six levels of section headings. `<h1>` is the highest section level while `<h6>` is the lowest.

# H1

## H2

### H3

#### H4

##### H5

###### H6

## Paragraph

Xerum, quo qui aut unt expliquam qui dolut labo. Aque venitatiusda cum, voluptionse latur sitiae dolessi aut parist aut dollo enim qui voluptate ma dolestendit peritin re plis aut quas inctum laceat est volestemque commosa as cus endigna tectur, offic to cor sequas etum rerum idem sintibus eiur? Quianimin porecus evelectur, cum que nis nust voloribus ratem aut omnimi, sitatur? Quiatem. Nam, omnis sum am facea corem alique molestrunt et eos evelece arcillit ut aut eos eos nus, sin conecerem erum fuga. Ri oditatquam, ad quibus unda veliamenimin cusam et facea ipsamus es exerum sitate dolores editium rerore eost, temped molorro ratiae volorro te reribus dolorer sperchicium faceata tiustia prat.

Itatur? Quiatae cullecum rem ent aut odis in re eossequodi nonsequ idebis ne sapicia is sinveli squiatum, core et que aut hariosam ex eat.

## Images

### Syntax

```markdown
![Alt text](./full/or/relative/path/of/image)
```

### Output

![blog placeholder](../../assets/blog-placeholder-about.jpg)

## Blockquotes

The blockquote element represents content that is quoted from another source, optionally with a citation which must be within a `footer` or `cite` element, and optionally with in-line changes such as annotations and abbreviations.

### Blockquote without attribution

#### Syntax

```markdown
> Tiam, ad mint andaepu dandae nostion secatur sequo quae.  
> **Note** that you can use _Markdown syntax_ within a blockquote.
```

#### Output

> Tiam, ad mint andaepu dandae nostion secatur sequo quae.  
> **Note** that you can use _Markdown syntax_ within a blockquote.

### Blockquote with attribution

#### Syntax

```markdown
> Don't communicate by sharing memory, share memory by communicating.<br>
> — <cite>Rob Pike[^1]</cite>
```

#### Output

> Don't communicate by sharing memory, share memory by communicating.<br>
> — <cite>Rob Pike[^1]</cite>

[^1]: The above quote is excerpted from Rob Pike's [talk](https://www.youtube.com/watch?v=PAAkCSZUG1c) during Gopherfest, November 18, 2015.

## Tables

### Syntax

```markdown
| Italics   | Bold     | Code   |
| --------- | -------- | ------ |
| _italics_ | **bold** | `code` |
```

### Output

| Italics   | Bold     | Code   |
| --------- | -------- | ------ |
| _italics_ | **bold** | `code` |

## Code Blocks

### Syntax

we can use 3 backticks ``` in new line and write snippet and close with 3 backticks on new line and to highlight language specific syntax, write one word of language name after first 3 backticks, for eg. html, javascript, css, markdown, typescript, txt, bash

````markdown
```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>Example HTML5 Document</title>
  </head>
  <body>
    <p>Test</p>
  </body>
</html>
```
````

### Output

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>Example HTML5 Document</title>
  </head>
  <body>
    <p>Test</p>
  </body>
</html>
```

## List Types

### Ordered List

#### Syntax

```markdown
1. First item
2. Second item
3. Third item
```

#### Output

1. First item
2. Second item
3. Third item

### Unordered List

#### Syntax

```markdown
- List item
- Another item
- And another item
```

#### Output

- List item
- Another item
- And another item

### Nested list

#### Syntax

```markdown
- Fruit
  - Apple
  - Orange
  - Banana
- Dairy
  - Milk
  - Cheese
```

#### Output

- Fruit
  - Apple
  - Orange
  - Banana
- Dairy
  - Milk
  - Cheese

## Other Elements — abbr, sub, sup, kbd, mark

### Syntax

```markdown
<abbr title="Graphics Interchange Format">GIF</abbr> is a bitmap image format.

H<sub>2</sub>O

X<sup>n</sup> + Y<sup>n</sup> = Z<sup>n</sup>

Press <kbd>CTRL</kbd> + <kbd>ALT</kbd> + <kbd>Delete</kbd> to end the session.

Most <mark>salamanders</mark> are nocturnal, and hunt for insects, worms, and other small creatures.
```

### Output

<abbr title="Graphics Interchange Format">GIF</abbr> is a bitmap image format.

H<sub>2</sub>O

X<sup>n</sup> + Y<sup>n</sup> = Z<sup>n</sup>

Press <kbd>CTRL</kbd> + <kbd>ALT</kbd> + <kbd>Delete</kbd> to end the session.

Most <mark>salamanders</mark> are nocturnal, and hunt for insects, worms, and other small creatures.
"""###,
        "src/content/blog/using-mdx.mdx": ###"""
---
title: 'Using MDX'
description: 'Lorem ipsum dolor sit amet'
pubDate: 'Jun 01 2024'
heroImage: '../../assets/blog-placeholder-5.jpg'
---

This theme comes with the [@astrojs/mdx](https://docs.astro.build/en/guides/integrations-guide/mdx/) integration installed and configured in your `astro.config.mjs` config file. If you prefer not to use MDX, you can disable support by removing the integration from your config file.

## Why MDX?

MDX is a special flavor of Markdown that supports embedded JavaScript & JSX syntax. This unlocks the ability to [mix JavaScript and UI Components into your Markdown content](https://docs.astro.build/en/guides/integrations-guide/mdx/#mdx-in-astro) for things like interactive charts or alerts.

If you have existing content authored in MDX, this integration will hopefully make migrating to Astro a breeze.

## Example

Here is how you import and use a UI component inside of MDX.  
When you open this page in the browser, you should see the clickable button below.

import HeaderLink from '../../components/HeaderLink.astro';

<HeaderLink href="#" onclick="alert('clicked!')">
	Embedded component in MDX
</HeaderLink>

## More Links

- [MDX Syntax Documentation](https://mdxjs.com/docs/what-is-mdx)
- [Astro Usage Documentation](https://docs.astro.build/en/basics/astro-pages/#markdownmdx-pages)
- **Note:** [Client Directives](https://docs.astro.build/en/reference/directives-reference/#client-directives) are still required to create interactive components. Otherwise, all components in your MDX will render as static HTML (no JavaScript) by default.
"""###,
    ]

    static let jpeg = "/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAA6ADAAQAAAABAAAAAgAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8IAEQgAAgADAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAMCBAEFAAYHCAkKC//EAMMQAAEDAwIEAwQGBAcGBAgGcwECAAMRBBIhBTETIhAGQVEyFGFxIweBIJFCFaFSM7EkYjAWwXLRQ5I0ggjhU0AlYxc18JNzolBEsoPxJlQ2ZJR0wmDShKMYcOInRTdls1V1pJXDhfLTRnaA40dWZrQJChkaKCkqODk6SElKV1hZWmdoaWp3eHl6hoeIiYqQlpeYmZqgpaanqKmqsLW2t7i5usDExcbHyMnK0NTV1tfY2drg5OXm5+jp6vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAQIAAwQFBgcICQoL/8QAwxEAAgIBAwMDAgMFAgUCBASHAQACEQMQEiEEIDFBEwUwIjJRFEAGMyNhQhVxUjSBUCSRoUOxFgdiNVPw0SVgwUThcvEXgmM2cCZFVJInotIICQoYGRooKSo3ODk6RkdISUpVVldYWVpkZWZnaGlqc3R1dnd4eXqAg4SFhoeIiYqQk5SVlpeYmZqgo6SlpqeoqaqwsrO0tba3uLm6wMLDxMXGx8jJytDT1NXW19jZ2uDi4+Tl5ufo6ery8/T19vf4+fr/2wBDAAICAgICAgMCAgMFAwMDBQYFBQUFBggGBgYGBggKCAgICAgICgoKCgoKCgoMDAwMDAwODg4ODg8PDw8PDw8PDw//2wBDAQICAgQEBAcEBAcQCwkLEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBD/2gAMAwEAAhEDEQAAAflVBx9x/9oACAEBAAEFAlJTX//aAAgBAxEBPwF//9oACAECEQE/AX//2gAIAQEABj8C4P8A/8QAMxABAAMAAgICAgIDAQEAAAILAREAITFBUWFxgZGhscHw0RDh8SAwQFBgcICQoLDA0OD/2gAIAQEAAT8h6Bwder//2gAMAwEAAhEDEQAAEI//xAAzEQEBAQADAAECBQUBAQABAQkBABEhMRBBUWEgcfCRgaGx0cHh8TBAUGBwgJCgsMDQ4P/aAAgBAxEBPxA6v//aAAgBAhEBPxB7v//aAAgBAQABPxAQj494X//Z"

    func projeto() async throws -> URL? {
        let raiz = FileManager.default.temporaryDirectory
            .appending(path: "odete-blog-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fm = FileManager.default
        for (caminho, corpo) in Self.arquivos {
            let f = raiz.appending(path: caminho)
            try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try corpo.write(to: f, atomically: true, encoding: .utf8)
        }
        try fm.createDirectory(at: raiz.appending(path: "src/assets"), withIntermediateDirectories: true)
        for n in ["1", "2", "3", "4", "5", "about"] {
            try Data(base64Encoded: Self.jpeg)!.write(to: raiz.appending(path: "src/assets/blog-placeholder-\(n).jpg"))
        }
        try #"{"name":"blog","type":"module","dependencies":{"astro":"^5.0.0"}}"#
            .write(to: raiz.appending(path: "package.json"), atomically: true, encoding: .utf8)
        guard let rep = try? await Installer(project: raiz, registry: HTTPRegistry())
            .install(add: [.init("zod@^4.3.6"), .init("@astrojs/rss@^4.0.0")]),
            !rep.installed.isEmpty
        else { return nil }
        return raiz
    }

    /// `semEscopo` tira os `data-astro-cid-*` que o `<style>` dos componentes põe em cada
    /// elemento: o que se confere é o resto da marcação.
    func pega(_ dev: DevServer, _ rota: String, semEscopo: Bool = false) async throws -> (String, HTTPURLResponse?) {
        let (d, r) = try await URLSession.shared.data(from: URL(string: rota, relativeTo: dev.url)!)
        let html = String(decoding: d, as: UTF8.self)
        return (semEscopo ? html.replacing(/\ data-astro-cid-[a-z0-9]+/, with: "") : html, r as? HTTPURLResponse)
    }

    /// A página sem os scripts, para a mensagem de erro caber no relatório do teste.
    func sem(_ html: String) -> String {
        String(html.replacing(/<script[\s\S]*?<\/script>/, with: "").prefix(1500))
    }

    @Test func modeloBlogDoCreateAstro() async throws {
        guard let raiz = try await projeto() else { return }
        let dev = DevServer(root: raiz)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .astro)
        defer { dev.stop() }

        let (home, rh) = try await pega(dev, "/", semEscopo: true)
        #expect(rh?.statusCode == 200, "\(sem(home))")
        #expect(home.contains("<title>Astro Blog</title>"), "\(sem(home))")
        let diag = await dev.diagnostics().map(\.text)
        #expect(home.contains(#"<link rel="canonical" href="https://example.com/""#), "o Astro.site não veio do config: \(diag)")
        #expect(home.contains("--font-atkinson"), "o <Font> não escreveu a variável")
        #expect(home.contains("Hello, Astronaut!"))

        let (lista, rl) = try await pega(dev, "/blog", semEscopo: true)
        #expect(rl?.statusCode == 200, "\(sem(lista))")
        #expect(lista.contains("Markdown Style Guide") && lista.contains("Using MDX"), "o getCollection não listou: \(lista.prefix(1200))")
        #expect(lista.contains(#"href="/blog/first-post/""#))
        #expect(lista.contains("/@odete/arquivo/src/assets/blog-placeholder-"), "o heroImage não virou imagem")

        let (post, rp) = try await pega(dev, "/blog/markdown-style-guide/", semEscopo: true)
        #expect(rp?.statusCode == 200, "\(sem(post))")
        #expect(post.contains("<h1>Markdown Style Guide</h1>"), "\(post.prefix(1200))")
        #expect(post.contains(#"<h2 id="headings">Headings</h2>"#), "o corpo em Markdown não veio")
        #expect(post.contains("<table>") && post.contains("data-footnotes"))

        let (mdx, rm) = try await pega(dev, "/blog/using-mdx/", semEscopo: true)
        #expect(rm?.statusCode == 200, "\(sem(mdx))")
        #expect(mdx.contains("Embedded component in MDX"), "o componente do MDX não renderizou: \(mdx.prefix(1500))")
        #expect(mdx.contains(#"onclick="alert(&#39;clicked!&#39;)""#), "o spread de props do HeaderLink não levou o onclick")

        let (sobre, rs) = try await pega(dev, "/about", semEscopo: true)
        #expect(rs?.statusCode == 200 && sobre.contains("<h1>About Me</h1>"), "\(sem(sobre))")

        // O endpoint: `getCollection` e o `@astrojs/rss` empacotado. O rss monta
        // `https:/example.com/` (uma barra), que o `URL` do runtime passou a aceitar.
        let (rss, rr) = try await pega(dev, "/rss.xml")
        #expect(rr?.statusCode == 200, "\(sem(rss))")
        #expect(rss.contains("<title>Astro Blog</title>") && rss.contains("https://example.com/blog/first-post/"), "\(sem(rss))")
        #expect(rr?.value(forHTTPHeaderField: "content-type")?.contains("xml") == true)

        let (_, rn) = try await pega(dev, "/blog/nao-existe/")
        #expect(rn?.statusCode == 404)

        let (css, _) = try await pega(dev, "/@odete/css/@astro/blog")
        #expect(css.contains("--accent: #2337ff"), "o global.css do BaseHead não chegou: \(css.prefix(300))")
    }
}
