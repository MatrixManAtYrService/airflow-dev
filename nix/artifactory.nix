# Artifactory overlay for redirecting Python package downloads from PyPI to corporate Artifactory
# This overlay handles URL redirection and SSL certificate configuration for corporate networks

{ lib }:

let
  # URL transformation function - converts PyPI URLs to Artifactory URLs
  redirectToArtifactory = url: builtins.replaceStrings
    [ "https://files.pythonhosted.org/packages" ]
    [ "https://artifactory.corp.clover.com/artifactory/api/pypi/libs-python/packages/packages" ]
    url;

  # Generate SSL attributes for corporate network access
  mkSslAttrs = cacert: {
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
    curlOpts = "--cacert ${cacert}/etc/ssl/certs/ca-bundle.crt";
  };

  # Override source URLs and add SSL config
  mkOverrideSourceAttrs = sslAttrs: srcAttrs:
    if srcAttrs ? url then
      { url = redirectToArtifactory srcAttrs.url; } // sslAttrs
    else if srcAttrs ? urls then
      { urls = map redirectToArtifactory srcAttrs.urls; } // sslAttrs
    else srcAttrs;

  # Override a single Python package to use Artifactory
  mkOverridePackage = overrideSourceAttrs: pkg:
    if pkg ? overrideAttrs && pkg ? src then
      pkg.overrideAttrs
        (old:
          if old ? src && old.src ? overrideAttrs then {
            src = old.src.overrideAttrs overrideSourceAttrs;
          } else old
        )
    else pkg;

  # Create overlay that applies package overrides to all packages in a set
  mkPackageSetOverlay = lib: overridePackage:
    lib.mapAttrs (_: overridePackage);

in
{
  inherit redirectToArtifactory mkSslAttrs mkOverrideSourceAttrs mkOverridePackage mkPackageSetOverlay;

  # Convenience function to create a complete nixpkgs overlay for Python packages
  mkNixpkgsOverlay = { cacert, lib }:
    let
      sslAttrs = mkSslAttrs cacert;
      overrideSourceAttrs = mkOverrideSourceAttrs sslAttrs;
      overridePackage = mkOverridePackage overrideSourceAttrs;

      # Override all packages in a Python package set
      overridePythonPackages = pythonPkgs: pythonPkgs.overrideScope (pyFinal: pyPrev:
        mkPackageSetOverlay lib overridePackage pyPrev
      );
    in
    {
      python312Packages = overridePythonPackages;
      python313Packages = overridePythonPackages;
      python311Packages = overridePythonPackages;
    };

  # Convenience function to create a pyproject overlay
  mkPyprojectOverlay = { cacert, lib }:
    let
      sslAttrs = mkSslAttrs cacert;
      overrideSourceAttrs = mkOverrideSourceAttrs sslAttrs;
      overridePackage = mkOverridePackage overrideSourceAttrs;
    in
    mkPackageSetOverlay lib overridePackage;
}