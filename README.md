# Avata

Current public release: [Avata 1.1.4 (58.17.10)](https://github.com/crosnuu12/Avata-kor-releases/releases/tag/v1.1.4).

Normal staged buys now use the selected market-regime table price as their limit order price, capped by the broker's actual daily upper limit when necessary. The journal retains actual execution prices and amounts. Main-PC diagnostic transmission from 1.1.3 remains included. See the [release notes](releases/1.1.4/RELEASE_NOTES.md) and [verified release status](releases/1.1.4/STATUS.md).

The signed automatic-update feed is [avata-update.json](https://github.com/crosnuu12/Avata-kor-releases/releases/latest/download/avata-update.json). Running installations with active orders may wait for the in-app update action, which uses the existing stop and cancel-confirmation sequence before installation.
