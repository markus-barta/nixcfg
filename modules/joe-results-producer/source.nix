# Minimal offline runtime: synthetic fixtures and tests never enter this output.
{ pkgs }:
pkgs.runCommand "joe-results-producer-source" { } ''
  mkdir -p "$out"
  cp ${./main.mjs} "$out/main.mjs"
  cp ${./sdk-decimal.mjs} "$out/sdk-decimal.mjs"
  cp ${./capture.mjs} "$out/capture.mjs"
  cp ${./fx.mjs} "$out/fx.mjs"
  cp ${./fifo.mjs} "$out/fifo.mjs"
  cp ${./journal.mjs} "$out/journal.mjs"
  cp ${./producer.mjs} "$out/producer.mjs"
  cp ${./transport.mjs} "$out/transport.mjs"
  cp ${./results-validation.mjs} "$out/results-validation.mjs"
  cp ${./position-proof.mjs} "$out/position-proof.mjs"
  cp ${./broker-backstop.mjs} "$out/broker-backstop.mjs"
  cp ${./verify-contracts.mjs} "$out/verify-contracts.mjs"
  cp ${./contracts.lock.json} "$out/contracts.lock.json"
  cp -r ${./contracts} "$out/contracts"
  ${pkgs.nodejs}/bin/node "$out/verify-contracts.mjs"
''
