use hbb_common::{bail, ResultType};
use serde_derive::Serialize;
use std::{path::PathBuf, time::Duration};

#[derive(Serialize, Debug)]
pub struct DownloadData {
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub data: Vec<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<PathBuf>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total_size: Option<u64>,
    pub downloaded_size: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

pub fn download_file(
    _url: String,
    _path: Option<PathBuf>,
    _auto_del_dur: Option<Duration>,
) -> ResultType<String> {
    bail!("Downloads are unavailable in the LAN-only build")
}

pub fn get_download_data(_id: &str) -> ResultType<DownloadData> {
    bail!("Downloads are unavailable in the LAN-only build")
}

pub fn cancel(_id: &str) {}
pub fn remove(_id: &str) {}
