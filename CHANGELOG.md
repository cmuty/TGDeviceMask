# 1.0.2

The previous package only loaded in the main Telegram app. Telegram's notification
service creates a separate network environment, which could report the real model
after the main application stopped. The loader filter and runtime guard now include
the NotificationService, NotificationContent, Share, Widget and SiriIntents extensions
using exact bundle IDs. Each process uses the same config and model hooks.

The existing deviceModel getter is used by MTRequestMessageService when serializing
initConnection. No UI replacement, account logout or authorization-data edits are used.

Diagnostics remain in each process's own tmp/TGDeviceMask-diagnostics.txt and now
include its bundle ID. No account/message data is collected.

After installation, use Dopamine's userspace restart to stop existing extension
processes, then open Telegram once. Verify the model from another authorized client
both while the app is open and after closing it and receiving a notification.
Successful package compilation does not establish that background verification passed.
The jailbreak and tweak injection must remain active; a stock boot cannot load this tweak.

Source evidence:
- https://github.com/TelegramMessenger/Telegram-iOS/blob/master/Telegram/NotificationService/Sources/NotificationService.swift
- https://github.com/TelegramMessenger/Telegram-iOS/blob/master/Telegram/BUILD
- https://github.com/TelegramMessenger/Telegram-iOS/blob/master/submodules/MtProtoKit/Sources/MTRequestMessageService.m
