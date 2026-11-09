# TG WS Proxy для iOS

Порт [tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy) на iPhone и iPad: локальный MTProto-прокси, который ускоряет Telegram, передавая его трафик через WebSocket.

## Установка

1. Скачай `TGWSProxy-N.ipa` из [Releases](../../releases).
2. Поставь его через iloader или SideStore.
3. Открой приложение и включи «Прокси для Telegram». iOS один раз спросит разрешение добавить VPN — разреши.
4. Нажми «Добавить прокси в Telegram» и включи прокси в Telegram.

Приложение работает как VPN, но трафик телефона через него не идёт: VPN-модуль нужен только для того, чтобы iOS не останавливала прокси, пока ты в Telegram.

## Как это устроено

- `ios/Tunnel/Engine` — перенос логики из `proxy/` на Swift: расшифровка рукопожатия, новое шифрование к Telegram, WebSocket-клиент, пул соединений, запасные пути.
- `ios/Tunnel/PacketTunnelProvider.swift` — VPN-модуль, в котором работает прокси.
- `ios/App` — приложение с настройками.

## Сборка

Сборку запускает изменение `ios/build.json` в `main` (или вручную, workflow «iOS IPA»). IPA появляется в Releases с тегом `ios-build-N`, список изменений берётся из `CHANGELOG-iOS.md`.
