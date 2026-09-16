use crate::models::*;
#[cfg(unix)]
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
};

pub struct Store {
    root: PathBuf,
}
impl Store {
    pub fn new(root: PathBuf) -> Result<Self> {
        fs::create_dir_all(&root)?;
        #[cfg(unix)]
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700))?;
        Ok(Self { root })
    }
    pub fn profile_dir(&self, id: &str) -> Result<PathBuf> {
        uuid::Uuid::parse_str(id)
            .map_err(|_| AppError::new("invalid_id", "Invalid profile identifier."))?;
        Ok(self.root.join(id))
    }
    pub fn profiles(&self) -> Result<Vec<Profile>> {
        let mut profiles = vec![];
        for e in fs::read_dir(&self.root)? {
            let e = e?;
            if !e.file_type()?.is_dir() {
                continue;
            }
            let path = e.path().join("profile.json");
            if !path.exists() {
                continue;
            }
            let p: Profile = serde_json::from_slice(&fs::read(path)?)?;
            if self.profile_dir(&p.id)? != e.path() {
                return Err(AppError::new(
                    "data",
                    "Profile directory identity mismatch.",
                ));
            }
            profiles.push(p);
        }
        profiles.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(profiles)
    }
    pub fn save(&self, profile: &Profile, content: Option<&str>) -> Result<()> {
        let dir = self.profile_dir(&profile.id)?;
        fs::create_dir_all(&dir)?;
        #[cfg(unix)]
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))?;
        if let Some(c) = content {
            atomic_write(&dir.join("config.ovpn"), c.as_bytes())?;
        }
        let mut clean = profile.clone();
        clean.remembered = false;
        atomic_write(
            &dir.join("profile.json"),
            &serde_json::to_vec_pretty(&clean)?,
        )
    }
    pub fn content(&self, id: &str) -> Result<String> {
        Ok(fs::read_to_string(
            self.profile_dir(id)?.join("config.ovpn"),
        )?)
    }
    pub fn delete(&self, id: &str) -> Result<()> {
        let p = self.profile_dir(id)?;
        if p.exists() {
            fs::remove_dir_all(p)?;
        }
        Ok(())
    }
}
fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let temp = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
    let mut opts = OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    opts.mode(0o600);
    let result = (|| {
        let mut f = opts.open(&temp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        fs::rename(&temp, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_path_traversal() {
        let t = tempfile::tempdir().unwrap();
        let s = Store::new(t.path().into()).unwrap();
        assert!(s.content("../../secret").is_err());
        assert!(s.delete("../").is_err());
    }
    #[test]
    fn persists_profile_without_remembered_state_or_password() {
        let t = tempfile::tempdir().unwrap();
        let s = Store::new(t.path().into()).unwrap();
        let mut p = crate::profile::parse(
            "client\nremote example.test\nauth-user-pass\n",
            None,
            "Demo",
        )
        .unwrap()
        .profile;
        p.remembered = true;
        s.save(&p, Some("config")).unwrap();
        let loaded = s.profiles().unwrap();
        assert_eq!(loaded.len(), 1);
        assert!(!loaded[0].remembered);
        assert_eq!(s.content(&p.id).unwrap(), "config");
        #[cfg(unix)]
        assert_eq!(
            fs::metadata(s.profile_dir(&p.id).unwrap().join("config.ovpn"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        s.delete(&p.id).unwrap();
        assert!(s.profiles().unwrap().is_empty());
    }
}
