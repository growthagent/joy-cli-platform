#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.31.0/Ff3fkK1TjYTVxMj9V21FP24ojTJXYk314Fbo1whBZ6Yf.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.10.2/7CdYzjBAJmprmnK45oTpmH6BXt76ZASN2Ck5uZQEoWsK.tar.zst",
}

import pf.Stderr
import pf.Stdout
import weaver.Cli
import weaver.Opt
import weaver.Param
import AppPlatformUrls
import CommandLine

## Points Roc apps at a platform URL, and the scripts at a basic-cli URL:
##
##     roc scripts/update_app_platform_urls.roc --platform-url URL examples tests/app.roc
##     roc scripts/update_app_platform_urls.roc --basic-cli-url URL
##
## A folder names the `.roc` files directly in it. Each app must declare a
## platform. `--basic-cli-url` points every script in scripts/ and ci/ at a
## basic-cli release, so run it from the repository root. Exits 1 on an error
## and 2 on a bad command line.
main! : _ => Try({}, _)
main! = |raw_args| {
	args = CommandLine.read!(cli, raw_args)?
	match (args.platform_url, args.paths, args.basic_cli_url) {
		(Ok(_), [], _) => return CommandLine.fail!(cli, "--platform-url needs paths")
		(Err(NoValue), [_, ..], _) => return CommandLine.fail!(cli, "paths need --platform-url")
		(Err(NoValue), [], Err(NoValue)) => return CommandLine.fail!(cli, "one of --platform-url and --basic-cli-url is required")
		_ => {}
	}
	match update!(args.paths, args.platform_url, args.basic_cli_url) {
		Ok([]) => {
			Stdout.line!("App platform URLs are already up to date.") ?? {}
			Ok({})
		}
		Ok(updated) => {
			Stdout.line!("Updated app platform URLs:") ?? {}
			updated.for_each!(|path| Stdout.line!("- ${path}") ?? {})
			Ok({})
		}
		Err(AppUrls(message)) => {
			Stderr.line!(message) ?? {}
			Err(Exit(1))
		}
	}
}

cli = Cli.finish_without_validating(
	{
		platform_url: Opt.maybe_str({ short: "", long: "platform-url", help: "The platform URL to point the apps at." }),
		basic_cli_url: Opt.maybe_str({ short: "", long: "basic-cli-url", help: "The basic-cli URL to point the scripts in scripts/ and ci/ at." }),
		paths: Param.str_list({ name: "paths", help: "The apps, and folders of apps, to point at the platform URL." }),
	}.Cli,
	CommandLine.config({ name: "update_app_platform_urls.roc", description: "Point Roc apps at a platform URL, and the scripts at a basic-cli URL." }),
)

update! : List(Str), Try(Str, [NoValue]), Try(Str, [NoValue]) => Try(List(Str), [AppUrls(Str)])
update! = |paths, platform_url, basic_cli_url| {
	apps =
		match platform_url {
			Ok(url) => AppPlatformUrls.update_apps!(paths, url)?
			Err(NoValue) => []
		}
	scripts =
		match basic_cli_url {
			Ok(url) => AppPlatformUrls.update_scripts!(url)?
			Err(NoValue) => []
		}
	Ok(apps.concat(scripts))
}
