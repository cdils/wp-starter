const wordpress = require('@wordpress/eslint-plugin');
const globals = require('globals');

module.exports = [
	{ ignores: [ '**/*.min.js', 'wp-content/vendor/**', 'cms/**' ] },
	...wordpress.configs.recommended,
	{
		languageOptions: {
			globals: {
				...globals.browser,
				...globals.node,
				wp: 'readonly',
				jQuery: 'readonly',
			},
		},
	},
];
