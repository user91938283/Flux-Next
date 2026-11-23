# Third-party notices

Flux-Next is an independent project. It is not affiliated with, endorsed by, or sponsored by GameLoaded Entertainment, AdministratorGnar, ThunderGemios10, or the original Flux Framework.

## Flux Framework

The public API and the single-script project layout are inspired by the Flux Framework created by AdministratorGnar and ThunderGemios10:

- https://github.com/AdministratorGnar/FluxRBX
- https://github.com/GameLoaded/Flux
- https://github.com/GameLoaded/FluxRBXLibs

Those repositories do not contain a license file. The current source tree and release artifacts from v0.3.0 onward do not include source code from them. Earlier commits, tags, and release binaries were removed from the public repository during the v0.3.0 cleanup.

The packages under `src/ReplicatedStorage/Packages` and the package loader in `init.server.lua` and `init.client.lua` are independent implementations. Public names and observable behavior are kept so existing Flux code can migrate without rewriting its call sites.

The MIT license in [LICENSE](LICENSE) applies only to the original code in this repository. It does not grant rights to the Flux name or to any third-party material.

Releases before v0.3.0 were removed from the public repository and should not be redistributed. Use v0.3.0 or later.

## Dependencies

Flux-Next has no runtime third-party dependencies. It uses only Roblox and Luau APIs.
