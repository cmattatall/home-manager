use serde::{Deserialize, Serialize};
use ts_rs::TS;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
pub const BUILD_ID: &str = env!("TETHER_BUILD_ID");
pub const MAX_FRAME: usize = 1024 * 1024;
pub const MAX_SOURCE: u64 = 64 * 1024;
pub const TOKEN_TYPES: [&str; 9] = [
    "keyword", "string", "comment", "number", "function", "variable", "operator", "type",
    "property",
];

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct SshDestination {
    pub destination: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct Machine {
    pub id: String,
    pub host: String,
    pub account: String,
    pub ssh: Option<SshDestination>,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct BuildInfo {
    pub version: String,
    pub build_id: Option<String>,
}

impl BuildInfo {
    pub fn current() -> Self {
        Self {
            version: VERSION.into(),
            build_id: Some(BUILD_ID.into()),
        }
    }
}

#[derive(Serialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct MachineStatus {
    pub installed: Option<BuildInfo>,
    pub expected: BuildInfo,
    pub can_update: bool,
    pub updating: bool,
}

#[derive(Clone, Serialize, TS)]
#[serde(rename_all = "camelCase")]
pub enum MachineUpdateState {
    Running,
    Cancelling,
    Succeeded,
    Failed,
    Cancelled,
}

#[derive(Clone, Serialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct MachineUpdate {
    pub state: MachineUpdateState,
    pub message: String,
    pub output: String,
}

#[derive(Serialize, TS)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum ConnectionEvent {
    Progress { message: String },
    Output { text: String },
    Connected { machine: Machine },
    Error { message: String },
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct DirectoryPage {
    pub path: String,
    pub parent: Option<String>,
    pub entries: Vec<String>,
    pub next_offset: Option<usize>,
    pub skipped: usize,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct Worktree {
    pub id: String,
    pub path: String,
    pub name: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct Source {
    pub id: String,
    pub path: String,
    pub text: String,
    #[serde(default)]
    pub highlights: Vec<u32>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub enum Scope {
    Uncommitted,
    Staged,
    Unstaged,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct ChangedFile {
    pub path: String,
    pub status: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct SourceEntry {
    pub path: String,
    pub directory: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct SourceDirectory {
    pub entries: Vec<SourceEntry>,
    pub next_offset: Option<usize>,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct Hunk {
    pub before_start: u32,
    pub before_end: u32,
    pub after_start: u32,
    pub after_end: u32,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct Comparison {
    pub id: String,
    pub scope: Scope,
    pub before: Option<Source>,
    pub after: Option<Source>,
    pub hunks: Vec<Hunk>,
    pub before_label: String,
    pub after_label: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct ReviewAnchor {
    pub comparison_id: String,
    pub side: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct AnalysisSource {
    pub source: Source,
    pub context: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct SourceLocation {
    pub source: Source,
    pub selection: Selection,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct Symbol {
    pub name: String,
    pub kind: u32,
    pub range: Selection,
    pub selection_range: Selection,
    pub children: Vec<Symbol>,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct Inspection {
    pub context: String,
    pub hover: Vec<String>,
    pub locations: Vec<SourceLocation>,
    pub symbols: Vec<Symbol>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct Selection {
    pub start_line_number: u32,
    pub start_column: u32,
    pub end_line_number: u32,
    pub end_column: u32,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct AnnotationInput {
    pub id: String,
    pub source_id: String,
    pub path: String,
    pub selection: Selection,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub review: Option<ReviewAnchor>,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct Annotation {
    pub input: AnnotationInput,
    pub excerpt: String,
    pub created_at: String,
    pub expires_at: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub enum Disposition {
    Open,
    Addressed,
    Resolved,
    Dismissed,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct DiscussionStatus {
    pub annotation_id: String,
    pub revision: u32,
    pub disposition: Disposition,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum DiscussionActor {
    Human { owner: String },
    Agent { thread: String, submission: String },
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct ResponseEvidence {
    pub path: String,
    pub source_id: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
pub struct ResponseSources {
    pub before: Option<Source>,
    pub after: Option<Source>,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub enum Freshness {
    Unchanged,
    Moved,
    Changed,
    Removed,
    Uncertain,
    Unknown,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct SourceAssessment {
    pub annotation_id: String,
    pub path: String,
    pub observed_at: String,
    pub baseline_id: Option<String>,
    pub current_id: Option<String>,
    pub freshness: Freshness,
    pub file_changed: Option<bool>,
    pub selection: Option<Selection>,
    pub detail: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
pub struct AssessedSources {
    pub assessment: SourceAssessment,
    pub original: Option<Source>,
    pub baseline: Option<Source>,
    pub current: Option<Source>,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct DiscussionEvent {
    pub id: String,
    pub annotation_id: String,
    pub actor: DiscussionActor,
    pub created_at: String,
    pub text: String,
    pub disposition: Disposition,
    pub based_on_revision: u32,
    pub applied: bool,
    pub evidence: Vec<ResponseEvidence>,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct Discussion {
    pub status: DiscussionStatus,
    pub events: Vec<DiscussionEvent>,
    pub next_offset: Option<u32>,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AgentResponseInput {
    pub id: String,
    pub feedback_id: String,
    pub annotation_id: String,
    pub token: String,
    pub text: String,
    pub paths: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResolutionInput {
    pub id: String,
    pub annotation_id: String,
    pub expected_revision: u32,
    pub disposition: Disposition,
    pub text: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct AmpSession {
    pub id: String,
    pub thread: String,
    pub title: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct FeedbackInput {
    pub id: String,
    pub session_id: String,
    pub annotation_ids: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub enum DeliveryStatus {
    Prepared,
    Uncertain,
    Accepted,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct Feedback {
    pub input: FeedbackInput,
    pub session: AmpSession,
    pub created_at: String,
    pub status: DeliveryStatus,
    pub detail: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct FeedbackPreview {
    pub feedback: Feedback,
    pub content: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    pub owner: String,
    pub version: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, TS)]
#[serde(rename_all = "camelCase")]
pub struct ManagedLaunch {
    pub id: String,
    pub dimensions: tether_terminal::Dimensions,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct ManagedSession {
    pub launch: ManagedLaunch,
    pub runtime: Option<String>,
    pub status: String,
    pub detail: String,
}

pub fn typescript() -> String {
    let declarations: String = [
        tether_terminal::Dimensions::decl(),
        tether_terminal::FrameStamp::decl(),
        tether_terminal::Frame::decl(),
        ManagedLaunch::decl(),
        ManagedSession::decl(),
        SshDestination::decl(),
        Machine::decl(),
        BuildInfo::decl(),
        MachineStatus::decl(),
        MachineUpdateState::decl(),
        MachineUpdate::decl(),
        ConnectionEvent::decl(),
        DirectoryPage::decl(),
        Worktree::decl(),
        Source::decl(),
        Scope::decl(),
        ChangedFile::decl(),
        SourceEntry::decl(),
        SourceDirectory::decl(),
        Hunk::decl(),
        Comparison::decl(),
        ReviewAnchor::decl(),
        AnalysisSource::decl(),
        SourceLocation::decl(),
        Symbol::decl(),
        Inspection::decl(),
        Selection::decl(),
        AnnotationInput::decl(),
        Annotation::decl(),
        Disposition::decl(),
        DiscussionStatus::decl(),
        DiscussionActor::decl(),
        ResponseEvidence::decl(),
        ResponseSources::decl(),
        Freshness::decl(),
        SourceAssessment::decl(),
        AssessedSources::decl(),
        DiscussionEvent::decl(),
        Discussion::decl(),
        AgentResponseInput::decl(),
        ResolutionInput::decl(),
        AmpSession::decl(),
        FeedbackInput::decl(),
        DeliveryStatus::decl(),
        Feedback::decl(),
        FeedbackPreview::decl(),
        Session::decl(),
    ]
    .into_iter()
    .map(|declaration| format!("export {declaration}\n"))
    .collect();
    format!(
        "{declarations}export const tokenTypes = {};\n",
        serde_json::to_string(&TOKEN_TYPES).unwrap()
    )
}
