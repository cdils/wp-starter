const path = require( 'path' );
const MiniCssExtractPlugin = require( 'mini-css-extract-plugin' );
const TerserPlugin = require( 'terser-webpack-plugin' );
const CssMinimizerPlugin = require( 'css-minimizer-webpack-plugin' );
const RemoveEmptyScriptsPlugin = require( 'webpack-remove-empty-scripts' );
const StyleLintPlugin = require( 'stylelint-webpack-plugin' );
const ESLintPlugin = require( 'eslint-webpack-plugin' );

const themeDir = path.resolve( __dirname, 'wp-content/themes/{{THEME_NAME}}' );

module.exports = ( env, argv ) => {
	const isProduction = argv.mode === 'production';

	return {
		devtool: isProduction ? false : 'source-map',
		externals: {
			jquery: 'jQuery',
		},
		entry: {
			main: [
				path.resolve( themeDir, 'assets/js/main.js' ),
				path.resolve( themeDir, 'assets/scss/main.scss' ),
			],
		},
		output: {
			filename: 'js/[name].min.js',
			path: path.resolve( themeDir, 'assets' ),
		},
		module: {
			rules: [
				{
					test: /\.s?css$/,
					use: [
						MiniCssExtractPlugin.loader,
						{
							loader: 'css-loader',
							options: {
								sourceMap: ! isProduction,
								url: false,
							},
						},
						{
							loader: 'sass-loader',
							options: {
								sourceMap: ! isProduction,
							},
						},
					],
				},
			],
		},
		plugins: [
			new RemoveEmptyScriptsPlugin(),
			new MiniCssExtractPlugin( { filename: 'css/[name].css' } ),
			// Lint while watching; CI lints separately so a build never waits on it.
			...( isProduction
				? []
				: [
						new StyleLintPlugin( {
							files: [ 'assets/scss/**/*.s?(a|c)ss' ],
							context: themeDir,
							customSyntax: 'postcss-scss',
						} ),
						new ESLintPlugin( {
							extensions: [ 'js', 'jsx' ],
							context: path.resolve( themeDir, 'assets/js' ),
							exclude: [ '**/*.min.js' ],
						} ),
				  ] ),
		],
		optimization: {
			minimizer: [
				new TerserPlugin( {
					include: /\.min\.js$/,
					extractComments: false,
				} ),
				new CssMinimizerPlugin(),
			],
		},
	};
};
