export const SITE_NAME = "GazeKeeper";
export const SITE_URL = "https://gazekeeper.hridya.tech";
export const DEVELOPER = "Hridya Agrawal";
export const CURRENT_VERSION = "v0.1.0";
export const MACOS_REQUIREMENT = "macOS 14";

export const RELEASES_URL = "https://github.com/hridaya423/gazekeeper/releases";
export const DMG_URL = `${RELEASES_URL}/latest/download/GazeKeeper.dmg`;
export const APPCAST_URL = `${SITE_URL}/appcast.xml`;
export const CONTACT_EMAIL = "hridyaagrawal4@gmail.com";

export function releaseAssetUrl(version: string): string {
  return `${RELEASES_URL}/download/${version}/GazeKeeper.dmg`;
}
