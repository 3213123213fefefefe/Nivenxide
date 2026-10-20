# Hydroxide padrão + extras do Sentinel (experimental)

Escolha aplicada: manter as implementações do Hydroxide nas funções repetidas e acrescentar os recursos exclusivos do outro script. Esta instalação é separada do Nivenxide e não inclui as modificações anteriores de mana, Vanguard, fontes, restart ou correção de casts.

## Uso

Descarregue o script que estiver ativo antes de iniciar esta versão. O menu principal é o Hydroxide padrão. Nele, a aba **Extras Sentinel** abre o painel adicional; **RightControl** também alterna esse painel. O painel adicional é separado para conservar a interface e o comportamento originais. Configure os recursos novos e salve o perfil no painel de extras.

Configurações do padrão: `HYDROXIDE_MERGED/standard-state`. Configurações dos extras: `HYDROXIDE_MERGED/state`. Arquivos e perfis do Nivenxide não são sobrescritos.

## Recursos e separação

- Hydroxide continua responsável por auto parry, silent aim, ESP de players/trinkets/ingredientes/minérios, movimento existente, macros, day farm, trinket bot e demais funções compartilhadas.
- O host adicional preserva as famílias de recursos do arquivo de referência: rune cast, autoclicker com filtros, ESP de monstros, cores de mana/vulnere, intent próprio, previsão de dash, indicador de dano, waypoints, boosts, Safe Server, healer, progressão, Rot/Scroom/Grip bots, Castle Rock, aliados/personalização, Judgement e skins de arma.
- Controles equivalentes aos do padrão são ocultos e seus toggles permanecem falsos no host adicional, inclusive após carregar configurações. Os módulos de suporte são inicializados para fornecer dependências aos recursos exclusivos.
- O núcleo de anti-cheat/KeyHandler do Sentinel não é inicializado. O Hydroxide conserva esse núcleo. O host usa o remoto de mana capturado pelo padrão quando disponível e os fallbacks de entrada do código de referência.
- A whitelist de rune cast se integra ao hook de cast do padrão. A opção correspondente precisa estar habilitada no painel de extras.
- Não foram incluídos o carregador de conta/sessão do fornecedor, tokens embutidos, compartilhamento externo de aparência ou integração com dispositivos. Consultas públicas de assets/presença usam endpoints do Roblox e respeitam o que esses endpoints disponibilizam.
- Proteções temporárias de bots novos são encaminhadas aos toggles de no-fall/no-killbrick do padrão; o estado anterior é restaurado ao terminar/descarregar. As implementações duplicadas ficam inativas. A confirmação de comportamento de cada bot ainda depende de teste no jogo.

## Verificação e limitações

Compilação com Luau 0.743 e testes simulados: construção dos módulos, isolamento de globais/configurações, bloqueio de duplicatas, carga ordenada, falha de inicialização e limpeza ao descarregar. Nenhum teste foi feito dentro do Roblox/Potassium. Bots, skins, assets e remotos precisam de validação em jogo.

Se um módulo falhar na inicialização, os extras são descarregados e o padrão continua ativo; o erro aparece no console F9. A aba **Extras Sentinel → Mostrar verificação dos módulos** exibe o relatório da sessão.

`ORIGINS.json` registra URLs e hashes dos dois arquivos utilizados. `standard.lua` conserva o código de gameplay do padrão, com alterações de transporte local, namespace de arquivos e ponte de extras. `ExtrasEngine.lua` contém os módulos extraídos do arquivo de referência; `ExtrasPolicy.lua` define a separação; `ExtrasRuntime.lua` gerencia a vida útil e as dependências.

A licença do Hydroxide está preservada em `LICENSE`. A fonte de referência e seus créditos estão registrados em `ORIGINS.json`; nenhuma licença adicional é presumida para esse material.
