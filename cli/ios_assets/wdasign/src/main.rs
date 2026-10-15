//! Sign an app bundle for one iPhone with a free Apple ID, without the phone
//! attached. The iOS rig's Wi-Fi service runs this to renew WebDriverAgent's
//! 7-day signature with no Mac.
//!
//! Usage: wdasign <apple-id> <app-dir> <udid> <state-dir>
//! The password comes from ISIDELOAD_PASSWORD. Apple asks for a 2FA code only
//! when the anisette identity in <state-dir> is new; the code is read from
//! stdin, and an empty line exits 3 so an unattended run reports it.
//! Prints the signed bundle path on stdout.
use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::{certificates::DevelopmentCertificate, developer_session::DeveloperSession, devices::DevicesApi},
    sideload::{SideloaderBuilder, TeamSelection, builder::MaxCertsBehavior},
    util::fs_storage::FsStorage,
};
use rootcause::Report;
use std::{env, path::PathBuf, process::exit};

/// Never revoke a certificate to make room: the Mac's WebDriverAgent build
/// is signed with one of them, and revoking it breaks that build at once.
async fn never_revoke(_: Vec<DevelopmentCertificate>) -> Result<Option<Vec<String>>, Report> {
    Ok(None)
}

#[tokio::main]
async fn main() {
    rustls::crypto::ring::default_provider().install_default().expect("rustls provider");
    isideload::init().expect("isideload init");
    tracing_subscriber::fmt().with_max_level(tracing::Level::INFO).with_writer(std::io::stderr).init();

    let args: Vec<String> = env::args().collect();
    if args.len() != 5 {
        eprintln!("usage: wdasign <apple-id> <app-dir> <udid> <state-dir>");
        exit(2);
    }
    let (apple_id, app, udid, state) = (&args[1], PathBuf::from(&args[2]), &args[3], PathBuf::from(&args[4]));
    let Ok(password) = env::var("ISIDELOAD_PASSWORD") else {
        eprintln!("ISIDELOAD_PASSWORD is not set");
        exit(2);
    };

    let two_factor = async |p: TwoFactorCallbackParams| {
        if p.unknown {
            eprintln!("2FA: Apple rejected the previous code");
        }
        eprintln!("2FA: enter the code Apple sent to your devices");
        let mut code = String::new();
        if std::io::stdin().read_line(&mut code).unwrap_or(0) == 0 || code.trim().is_empty() {
            eprintln!("2FA: Apple asked for a code and none was given");
            exit(3);
        }
        Ok(TwoFactorCallbackResponse::SubmitCode(code.trim().to_string()))
    };

    let mut account = match AppleAccount::builder(apple_id)
        .anisette_provider(
            RemoteV3AnisetteProvider::default()
                .expect("anisette provider")
                .set_storage(Box::new(FsStorage::new(state.join("anisette"))))
                .set_serial_number("2".to_string()),
        )
        .login(&password, two_factor)
        .await
    {
        Ok(a) => a,
        Err(e) => {
            eprintln!("login failed: {e}");
            exit(1);
        }
    };
    let mut dev = DeveloperSession::from_account(&mut account).await.expect("developer session");
    let mut sideloader = SideloaderBuilder::new(dev.clone(), apple_id.to_string())
        .team_selection(TeamSelection::First)
        .max_certs_behavior(MaxCertsBehavior::Prompt(never_revoke))
        .storage(Box::new(FsStorage::new(state.join("sideload"))))
        .machine_name("devvm-ios-rig".to_string())
        .delete_app_after_install(false)
        .build();
    let team = sideloader.get_team().await.expect("team");
    if let Err(e) = dev.ensure_device_registered(&team, "ios-rig", udid, None).await {
        eprintln!("device registration failed: {e}");
        exit(1);
    }
    match sideloader
        .sign_app(app, Some(team), false, None::<fn(f32) -> std::future::Ready<()>>, None, Some(udid))
        .await
    {
        Ok((out, _)) => println!("{}", out.display()),
        Err(e) => {
            eprintln!("signing failed: {e}");
            exit(1);
        }
    }
}
