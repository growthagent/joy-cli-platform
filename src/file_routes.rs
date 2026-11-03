//! Paths the host answers from file roots by itself, before a request collects
//! its body or waits for a handler, so a file never waits behind requests the
//! handlers are busy with.
//!
//! A request below a route gets the file from the first of the route's roots
//! that has it. What the file server does for a file, conditional and range
//! requests included, stays in the file server.

use crate::file_server::{FilePlan, FileService};
use crate::server::ServerResponse;
use hyper::header::{HeaderValue, CONTENT_DISPOSITION};
use hyper::http::request::Parts;
use hyper::{Method, StatusCode};

/// What happens to a request below a route that no file answers.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Miss {
    /// The route owns its path: a 404, or a 405 for a method other than `GET`
    /// and `HEAD`, and no handler hears of it.
    NotFound,
    /// The handler answers it.
    AskHandler,
}

#[derive(Debug)]
pub(crate) struct FileRouteSpec {
    pub(crate) path: String,
    pub(crate) roots: Vec<String>,
    pub(crate) miss: Miss,
    pub(crate) download: bool,
}

#[derive(Debug)]
pub(crate) struct FileRoutes {
    /// Longest path first, so the most specific route wins.
    routes: Vec<FileRouteSpec>,
}

impl FileRoutes {
    pub(crate) fn activate(specs: Vec<FileRouteSpec>, files: &FileService) -> Result<Self, String> {
        for spec in &specs {
            if !spec.path.starts_with('/') {
                return Err(format!("the file route {:?} must start with /", spec.path));
            }
            if spec.roots.is_empty() {
                return Err(format!("the file route {:?} has no roots", spec.path));
            }
            if let Some(root) = spec.roots.iter().find(|root| !files.has_root(root)) {
                return Err(format!(
                    "the file route {:?} names {root:?}, which is not one of the server's roots",
                    spec.path
                ));
            }
        }
        Ok(Self::longest_first(specs))
    }

    fn longest_first(specs: Vec<FileRouteSpec>) -> Self {
        let mut routes: Vec<FileRouteSpec> = specs
            .into_iter()
            .map(|spec| FileRouteSpec {
                path: spec.path.trim_end_matches('/').to_owned(),
                ..spec
            })
            .collect();
        routes.sort_by_key(|route| std::cmp::Reverse(route.path.len()));
        Self { routes }
    }

    /// The route `path` is at or below, and the part of `path` below it.
    fn matching<'a>(&self, path: &'a str) -> Option<(&FileRouteSpec, &'a str)> {
        self.routes.iter().find_map(|route| {
            let rest = path.strip_prefix(route.path.as_str())?;
            if rest.is_empty() {
                Some((route, rest))
            } else {
                rest.strip_prefix('/').map(|relative| (route, relative))
            }
        })
    }

    /// The answer to a request below a route, `None` when the handler gives it.
    pub(crate) async fn answer(
        &self,
        files: &FileService,
        parts: &Parts,
    ) -> Option<ServerResponse> {
        let (route, relative) = self.matching(parts.uri.path())?;
        let names_file = !relative.is_empty() && !relative.ends_with('/');
        let reads = parts.method == Method::GET || parts.method == Method::HEAD;
        if route.miss == Miss::AskHandler && !(reads && names_file) {
            return None;
        }
        let mut missing = None;
        for root in &route.roots {
            let plan = FilePlan {
                root: root.clone(),
                relative: relative.to_owned(),
                cache: None,
            };
            let mut response = files.serve(plan, &parts.method, &parts.headers).await;
            if response.status() != StatusCode::NOT_FOUND {
                if route.download && response.status().is_success() {
                    add_download_name(&mut response, relative);
                }
                return Some(response);
            }
            missing = Some(response);
        }
        match route.miss {
            Miss::NotFound => missing,
            Miss::AskHandler => None,
        }
    }
}

/// Name a download after the last part of its path, which `filename*` takes
/// percent encoded, the way it stands in the URL.
fn add_download_name(response: &mut ServerResponse, relative: &str) {
    let name = relative.rsplit('/').next().unwrap_or(relative);
    if let Ok(value) = HeaderValue::from_str(&format!("attachment; filename*=UTF-8''{name}")) {
        response.headers_mut().insert(CONTENT_DISPOSITION, value);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(path: &str, roots: &[&str]) -> FileRouteSpec {
        FileRouteSpec {
            path: path.to_owned(),
            roots: roots.iter().map(|root| (*root).to_owned()).collect(),
            miss: Miss::NotFound,
            download: false,
        }
    }

    fn matched(routes: &FileRoutes, path: &str) -> Option<(String, String)> {
        routes
            .matching(path)
            .map(|(route, relative)| (route.path.clone(), relative.to_owned()))
    }

    #[test]
    fn the_longest_route_wins_and_only_whole_segments_match() {
        let routes = FileRoutes::longest_first(vec![
            spec("/videos", &["a"]),
            spec("/download/videos/", &["a"]),
            spec("/download", &["a"]),
        ]);
        let found = |route: &str, relative: &str| Some((route.to_owned(), relative.to_owned()));
        assert_eq!(
            matched(&routes, "/videos/a/b.mp4"),
            found("/videos", "a/b.mp4")
        );
        assert_eq!(matched(&routes, "/videos"), found("/videos", ""));
        assert_eq!(matched(&routes, "/videos/"), found("/videos", ""));
        assert_eq!(matched(&routes, "/videosx/a.mp4"), None);
        assert_eq!(
            matched(&routes, "/download/videos/a.mp4"),
            found("/download/videos", "a.mp4")
        );
        assert_eq!(
            matched(&routes, "/download/a.mp4"),
            found("/download", "a.mp4")
        );
        assert_eq!(matched(&routes, "/other"), None);
    }

    #[test]
    fn a_route_at_the_top_matches_everything_after_the_others() {
        let routes = FileRoutes::longest_first(vec![spec("/", &["a"]), spec("/videos", &["a"])]);
        let found = |route: &str, relative: &str| Some((route.to_owned(), relative.to_owned()));
        assert_eq!(matched(&routes, "/app.wasm"), found("", "app.wasm"));
        assert_eq!(matched(&routes, "/"), found("", ""));
        assert_eq!(matched(&routes, "/videos/a.mp4"), found("/videos", "a.mp4"));
    }

    #[test]
    fn a_route_must_be_a_path_with_roots_the_server_has() {
        let files = FileService::activate(Vec::new()).expect("no roots to open");
        let problem = |specs| FileRoutes::activate(specs, &files).unwrap_err();
        assert!(problem(vec![spec("videos", &["a"])]).contains("must start with /"));
        assert!(problem(vec![spec("/videos", &[])]).contains("has no roots"));
        assert!(problem(vec![spec("/videos", &["a"])]).contains("not one of the server's roots"));
    }
}
