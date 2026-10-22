export const SITE_NAME = "GazeKeeper";
export const SITE_URL = "https://gazekeeper.hridya.tech";
export const DEVELOPER = "Hridya Agrawal";
export const CURRENT_VERSION = "v0.1.0";
export const MACOS_REQUIREMENT = "macOS 14";

// Downloads and update feed live on the site's own release endpoints.
// gazekeeper.hridya.tech must serve these paths before the site ships.
export const DMG_URL = `${SITE_URL}/releases/GazeKeeper.dmg`;
export const APPCAST_URL = `${SITE_URL}/appcast.xml`;
export const CONTACT_EMAIL = "hridyaagrawal4@gmail.com";

export function releaseAssetUrl(version: string): string {
  return `${SITE_URL}/releases/GazeKeeper.${version}.dmg`;
}
