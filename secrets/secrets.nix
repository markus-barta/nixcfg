# Agenix Secrets Configuration
# https://github.com/ryantm/agenix
#
# Workflow:
#   1. Add your host's SSH key to this file
#   2. Create secret: agenix -e secrets/SECRETNAME.age
#   3. Reference in config: age.secrets.SECRETNAME.file = ./secrets/SECRETNAME.age;
#   4. After key changes: just rekey

let
  # ============================================================================
  # USER KEYS
  # ============================================================================
  # Personal SSH keys that can decrypt secrets for editing

  # Markus' personal key (~/.ssh/id_rsa)
  markus = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H1iVXWYKnHkxQsS7tGsZq3SoHxlVccd+kroMC/DhC4MWwVnJInWwDpo/bz7LiLuh+1Bmq04PswD78EiHVVQ+O7Ckk32heWrywD2vufihukhKRTy5zl6uodb5+oa8PBholTnw09d3M0gbsVKfLEi4NDlgPJiiQsIU00ct/y42nI0s1wXhYn/Oudfqh0yRfGvv2DZowN+XGkxQQ5LSCBYYabBK/W9imvqrxizttw02h2/u3knXcsUpOEhcWJYHHn/0mw33tl6a093bT2IfFPFb3LE2KxUjVqwIYz8jou8cb0F/1+QJVKtqOVLMvDBMqyXAhCkvwtEz13KEyt"
  ];

  # gb's key (user on hsb8)
  gb = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINmt2Fio1JUABm/dq0XMI4J4juZl3DC0AQBGOXuEnUfD gb@hsb8"
  ];

  # ============================================================================
  # HOST KEYS
  # ============================================================================
  # SSH host keys from each server (get with: ssh-keyscan hostname)

  hsb0 = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC2WZLgDFx1FGa7Veoy+KIpN3cHywnBsXo+ytLBpYnzT9uaxb+YI94k2zi+c67YJnN5gpX/EpGn3vXpCyJHZZHg4hJWjjj2kbXZv7op1MSusGCAP7HbR4a+dasF9mAZLOwzbnpLRwFUg+/Fjb0iAb3ri1sISEzAhkUkKuxJogNl7kqytFWexPkPb8J5Qvf+V6KnACB67G/T3bBf8u3R4IDp7EKOaCQwz8aWeuBrNNJevecPtfBuq3Uj/FipMMCHuHi4X95Q7V2OOUDuWxqcGz/iLUswoW+z1qE5Vv47W9J+QledsHCJhMzjsTZCknRorZyqzrzeicIqHpQvUvQKznWQwI50Op2AbYRPd3gwUmnCCUy5b5FWdmVWyzdSqfOiqYU1AKvY75bl1L6wQVOH/3RRHOfRNA3u6o9DnUhK/kSDv34Vl0kzm6fbqJX+uh6LRdMfioWmbeqTq62SZFt/a0xogMTQdjQS5M6yoZmbIVmC3L0k+IPrt+UVmlwm0gu0zbeTtzjLlyHe2X4AttoMr6OcMoLvst3SmJebS6CJcwT1Aca5MRqTcfzJZ/Fuy68ByaGIW9zPG1xp+/P4BvT53/OnUYbjaoln7yiOySHozafrAQ28p5goE+ITCmwJGxZxfceskvkir67kdxAT8GQoWR5i/Sarpal0FoVY7prV+OFm+w=="
  ];

  hsb8 = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDeDdND1TRTYc6rnn/xMMhNHe6I8DJ5bQxZWT3GI2wHUcd4RpkkSUhtIhjYwbwtdi3nRYlsRKPeqZ8sERNAORkThdMy9ueMq3oDwrTlMbs6jlS8atbZPiozkOji2g00+xrb2tTp0480+M2kKIYv8gSN7lHzjnA3i128YN1NNsbqanU/pZVaEe0M10G9TMWifdZqQnGxFjWrMxlSCOwhvC7OixCLbKi4YPiVQ/LkeF67su1i68qZQgJRftx9te7AJm19P4gIz2Tn+OI0a4iESnLzA4PD2Zu7eBo63B35u0ardlH1AZK7GZIa4DFAcaCp3xpRQ1N5RKEjAfYi1LhSWh2UvsVp2vFTc7NvOcSCdR6BjumcGk2k/3b71YGfAWxI+7VY74eeugVIpsAWY3ewGikn2qYQrv8Op374dLVBpmtrBZG7mXayk2uqQIdybXNFm7drsXVPDenD/Dl/mewYRmzb2vcSyLDS5sevBBgNmvMdNNyrbdjXZEo8j0IkExrYkng5p/AMgC4pUV6X/tcGTk//QnknWESmtcNeYjJy17kBiSOwZ4+WjEltqQMqMyf6elIjhN56ZhdCSTUVGe8d4t4NcCj4aS2K3rLJIR7cMFpmXTr+Bo9g/Oj3Lnoj0i8R82CjTY/0fuZSOsqpFdOAhgXGyEIHmglxC2fcyxcMZJAFaQ=="
  ];

  hsb1 = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIU0cAsXtdYPO5W4ns6utAEkVvzcmOx5Xl/nVF/fvAVz"
  ];

  csb0 = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKQk8oklcJePMtYjjBCgKaTrzZ4kqad84htRV9fzOVSd"
  ];

  csb1 = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHWQjoKsgp+4m8M2ztlDSYtiW80loYfYMeYYJCfhIh7g"
  ];

  gpc0 = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFpykoFcMPeCtWH3aColM4fzCsslUxaHwW9DHSTi2Fr3"
  ];

in
{
  # ============================================================================
  # ACTIVE SECRETS
  # ============================================================================

  # AdGuard Home static DHCP leases for hsb0
  # Format: JSON array of {mac, ip, hostname}
  # Edit: agenix -e secrets/static-leases-hsb0.age
  "static-leases-hsb0.age".publicKeys = markus ++ hsb0;

  # AdGuard Home static DHCP leases for hsb8
  # Format: JSON array of {mac, ip, hostname}
  # Edit: agenix -e secrets/static-leases-hsb8.age
  "static-leases-hsb8.age".publicKeys = markus ++ gb ++ hsb8;

  # MQTT credentials for UPS status publishing on hsb0
  # Format: KEY=VALUE lines (MQTT_HOST, MQTT_USER, MQTT_PASS)
  # Edit: agenix -e secrets/mqtt-hsb0.age
  "mqtt-hsb0.age".publicKeys = markus ++ hsb0;

  # NixFleet agent API token
  # Format: NIXFLEET_TOKEN=xxx (for NixOS EnvironmentFile)
  # Edit: agenix -e secrets/nixfleet-token.age
  "nixfleet-token.age".publicKeys = markus ++ hsb0 ++ hsb1 ++ hsb8 ++ csb0 ++ csb1 ++ gpc0;

}
