# Blade 23 — tudo no mesmo PC

O Sentinel usa filas em arquivos locais do executor. Configure todas as contas no mesmo PC, no mesmo servidor do Roblox e com acesso à mesma pasta de arquivos do executor. Não é necessário Python, `.bat`, endereço de servidor, convite ou teste de conexão entre computadores. Configurações remotas antigas são substituídas pelo modo local.

## Carregar e atualizar

Pare a versão anterior em **Config → Unload** ou reentre no jogo. Execute:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/3213123213fefefefe/Nivenxide/main/blade23/loader.lua", true))()
```

A aba **blade 23** contém **Blade / Sigil**, **Rot** e **Filas**. A aba **Pontos do mapa** foi removida; a rota fixa existente permanece. Os controles antigos de conexão, rota, meta de dano, marcação de coleta e Cela XP ficam ocultos; suas funções foram preservadas internamente.

## Configurações, aliados e proteção

Todas as configurações da aba **blade 23** são salvas automaticamente por conta em `sentinel/.cache/blade23_settings_<UserId>.json`, verificadas a cada segundo e gravadas somente quando mudam. Também entram no **Save Config**, incluindo teclas e seleções de contas offline. O último salvamento automático é restaurado após o autoload de perfil, antes de liberar a inicialização dos bots. Carregar manualmente outro perfil aplica suas opções e atualiza o salvamento automático. Iniciar/Parar e os estados internos dos trabalhadores não são configurações e não ligam o bot por causa desse arquivo. A retomada autorizada após hop continua usando o mecanismo existente.

Contas com a versão atual do Sentinel carregada no mesmo PC são anunciadas automaticamente por arquivos locais em `sentinel/.cache/blade_local_clients/`, independentemente de estarem em uma fila, rodando XP/ROT ou aguardando no menu. O proximity check reconhece UserId, servidor e mapa; anúncios vencem após 8 segundos sem atualização e ficam inativos no Unload. Atualize todas as contas e use a mesma pasta de arquivos do executor. Pastas isoladas não permitem identificar os outros clientes; nesse caso, selecione as contas manualmente como aliados. A identificação automática é temporária e não altera sua lista permanente de aliados.

Em **Aliados do servidor**, selecione as contas presentes; a identificação salva usa UserId. Aliados selecionados e **Alts** de ROT ficam excluídos da verificação de proximidade, inclusive com Ignore Friendly ativo. As listas preservam contas offline até você removê-las. Para configurar outra conta, use o perfil desejado nessa conta; cada conta mantém seu próprio último ajuste automático.

**Proximity Check**, **Skip Illusionist Server** e **Stay In Server** têm controles separados para Gaia e Khei. Com Stay In Server e uma ameaça configurada, o Sigil salva o progresso, encerra o trabalhador e vai ao menu no mesmo servidor. Aguarda **Play manual** e o personagem reaparecer antes de retomar a etapa salva. Ao retomar o XP, reaplica a espera de entrada da cela e dos mobs, preservando os contadores. **Parar Sigil** cancela a retomada pendente. A opção **Menu por Illusionist quando Super (Gaia)** pode solicitar esse menu mesmo sem Stay In Server.

O leaderboard conserva as funções anteriores e inicializa mesmo sem as APIs de introspecção. Linhas podem ser associadas por UserId, nome de usuário ou nome de personagem único; nomes ambíguos não são atribuídos a uma conta por palpite. A integração anterior com o executor permanece como alternativa. A apresentação efetiva precisa de teste no cliente.

## Contas Blade / Sigil

Configure tudo antes de iniciar:

1. Escolha **Rots** ou **Quests**.
2. Escolha **Shriekers**, **Zombie Scrooms** ou **Automatic**.
3. Configure a velocidade, padrão **100**, e a quantidade mínima de Shriekers.
4. Para Rots, selecione em **Alts** as contas fornecedoras que serão entregues ao Bounty Officer.
5. Habilite Blatant Mode e clique **Iniciar Sigil**. O botão **Parar Sigil** interrompe a execução e libera as configurações.

As opções são registradas para a execução e ficam bloqueadas enquanto o bot roda. A retomada preserva o progresso individual; uma conta que já terminou uma etapa não refaz essa etapa automaticamente. Uma execução nova marca spawn em **Alana** antes da coleta. Não é preciso escolher uma fase de início na interface.

### Coleta e espada

A conta percorre P1 → P2 → PE3. PE3 é a espera da fila de coleta. Apenas a dona da vez entra em P4 e ativa AutoBagPickup com alcance de **50 studs**:

| Método | Suprimentos necessários |
| --- | --- |
| Rots | 100 Silver; sem poções |
| Quests | 660 Silver; 1 Liquid Wisdom, 1 Health Potion, 1 Ice Protection e 5 Tespian Elixir |

A coleta usa o Auto Bag do Sentinel para alcançar o Silver sem deslocar a conta até cada bolsa. As poções necessárias usam interação por toque dentro dos mesmos 50 studs.

Ao concluir, desativa a coleta, sai para P5 e libera a vaga. Compra a Bronze Sword local próxima de P5 e confirma a espada no inventário antes de continuar. Se a espada local não aparecer, aguarda; a compra não usa a loja distante de Santorini. A compra executa uma tentativa por vez, sem prender o personagem no ar, confirma o inventário e respeita intervalo de 3 segundos antes de tentar novamente.

Nos pontos de espera PE3, P4, P5, PE8, P9, P10, PG11, PE13 e P14, o bot desliga Flight, Better Flight e Noclip ao chegar, restaura a colisão e permite que a conta caia até o piso. A queda desde a coordenada elevada não dispara uma nova subida a cada atualização. Os deslocamentos usam seu próprio noclip temporário e liberam o tween e sua conexão ao terminar.

### XP

Shriekers usa P6 → P7 → PE8. PE8 é a espera do farm; uma conta downada espera recuperar antes de ir a P9. **Automatic** pode usar Zombie Scrooms quando sua vaga estiver disponível; **Zombie Scrooms** usa o farm original e dispensa a aproximação ao Shrine.

Antes de iniciar o combate com Shriekers, a conta exige a quantidade mínima configurada e todos os alvos da cela com HP cheio durante **3 segundos contínuos**. Essa checagem acontece apenas na entrada da sessão. O detector aceita a sobreposição do corpo de um mob com a borda da cela, com limite horizontal de 3 studs e tolerância vertical para mobs empilhados, e tolera arredondamento de até 0,05 HP. Isso não considera um hit de 8 como HP cheio. A linha PE8 informa quantidade na cela, mínimo, full HP, alvos fora da área e o dono de uma vaga ocupada. Uma reserva válida de Shriekers permite entrar mesmo com Danger ativo; as outras rotinas mantêm sua espera anterior. A conta passa por P9 e usa o ponto de ataque fixo da cela Necro:

- Posição: `(2268.965087890625, 62.999996185302737, 783.982666015625)`.
- Cantos: `(2272.9111328125, 62.99999237060547, 791.964599609375)` e `(2265.51806640625, 62.99999237060547, 776.548583984375)`.
- Mapa: `5208655184`.

O farm soma as quedas individuais de HP até **6.700 de dano com espada**, depois desequipa a arma, confirma **3 socos sem carregar mana** para desbloqueá-la e faz **300 de dano com socos de mana**, em sequências de quatro M1 após cada carga até aproximadamente 95% de mana. O alcance dos socos é de aproximadamente 5 studs. Curas atualizam a referência de HP sem somar nem subtrair do contador. Os contadores de espada, socos sem mana (um por M1 confirmado, mesmo atingindo vários mobs) e dano com mana são salvos por conta para retomada. O dano dos três socos iniciais não é somado à meta dos socos de mana. A confirmação de carga em 95% é capturada antes de soltar a mana e da espera de liberação; a queda passiva nesse intervalo não cancela a sequência. O bot espera o marcador Charge desaparecer antes dos quatro M1 e respeita o término de LightAttack entre eles. Auto Charge, Snap Train e Train Climb cedem o controle durante a sequência; a liberação também solta G caso a carga tenha começado pelo teclado. Os três socos normais existentes permanecem iguais.

A mira procura atingir o maior número de alvos dentro do alcance estimado, usando a direção e pequenos ajustes de posição na cela. A geometria é uma estimativa; a eficácia física deve ser conferida no jogo.

Ao concluir, sai por P10 e espera o Danger desaparecer antes de avançar. A vaga de XP só é liberada após sair do local de farm.

### Orderly e treino

**Rots:** PG11 executa a marcação de spawn em **Renova Town**, sem lançar Gate. A conta segue P12 → PE13, espera sua vez e só então entra em P14. O Master troca automaticamente pela fila. O mínimo de Shriekers usa o valor atual configurado na interface, inclusive na retomada; cada participante verifica seu próprio mínimo. Após **16 entregas confirmadas**, avança para o treino e libera a próxima receptora. Cada entrega é vinculada ao personagem da vítima carregada. O contador só avança após observar **Jailed** nessa vítima e confirmar a liberação do colo por pelo menos 0,5 segundo; a frase do NPC sozinha não conta. A confirmação aguarda até 12 segundos, sem buscar outra vítima nesse intervalo. Eventos repetidos e replays do diálogo não somam novamente. Uma entrega pendente fica preservada durante a pausa por menu para ser resolvida na retomada. O progresso parcial é salvo em cada entrega e retomado na mesma execução; a interface diferencia a contagem da etapa (0–16) do total histórico. O botão de zerar total fica bloqueado com bots, fila ou entrega ativos. Contagens antigas não são corrigidas por estimativa.

**Quests:** usa a sequência existente de missões e poções. O treino de Warrior compra apenas **Pommel Strike**, **Action Surge** e **Plate Training** com Alfric, com limite persistente de três compras confirmadas, considerando também skills já obtidas. Respostas de pagamento duplicadas no mesmo diálogo são bloqueadas antes do envio. Se faltar Silver, Orderly ou XP, permanece no trainer, coleta Silver próximo e tenta novamente após 15 segundos. Não refaz a estalagem e a viagem entre cada tentativa. Em Castle Sanctuary, visita Draug logo após marcar spawn, usa o diálogo existente e confirma a conversa antes de ir a Jagen. Aguarda a compra e a skill Ultra de Jagen antes de seguir ao treino existente de Mana Dash e depois Ya'alda/Khei. A rota Blade não desvia para o day farm em Santorini antes dessa compra.

## Contas fornecedoras de Rot

Na subaba **Rot**, habilite Blatant Mode, ajuste a retomada após rejoin e a tecla de parada e clique **Iniciar Rot**. Não inicie a progressão Sigil nessa mesma conta. O botão inicia o papel de fornecedora e não exige Master manual.

A preparação existente em Santorini/Shore 4 mantém as condições de Rot. Em Renova, a fornecedora espera em `(-2085.454589844, 609.353881836, -754.801147461)`. A vítima escolhe qualquer outro jogador vivo e livre a até 6 studs na horizontal de P14, com tolerância de 12 studs na altura. A identificação vem dos personagens presentes no servidor e funciona mesmo quando a receptora está em outro PC, sem registro compartilhado ou Master manual. Vítimas conhecidas do Rot Bot no mesmo PC são excluídas. Enquanto a pessoa carrega outra conta, está downada ou fora do ponto, as fornecedoras aguardam. Por presença não é possível ler a contagem de 16 Rots do outro PC: a receptora deve sair do ponto quando terminar. A progressão Blade / Sigil normalmente faz isso ao seguir ao treino.

A vítima usa o voo temporário existente do Sentinel para chegar ao Master e só se downa quando está próxima e a receptora continua livre. A receptora anda até a conta downada, carrega e entrega no Bounty Officer de Renova usando o pathfinder existente. Após a entrega, retorna à região de P14 antes de buscar outra conta. A fornecedora executa wipe/respawn antes do rejoin. A retomada pressiona Play antes de iniciar a preparação, inclusive quando o menu já contém um personagem provisório. A opção de retomada usa o loader do GitHub após a troca de servidor; o executor precisa oferecer `queue_on_teleport` ou `queueteleport` e permitir a execução após a troca.

Use **Parar Rot Bot e cancelar retomada** ou a tecla configurada, padrão **F8**, para interromper e cancelar a retomada.

## Filas e pontos

**Filas** mostra a dona da coleta, os participantes, suas etapas, pontos de espera, contadores de XP e o turno de Rot. A coordenação usa arquivos locais; executores com pastas isoladas não enxergam a mesma fila.

O arquivo `routes/Blade.json` preserva os 14 pontos enviados. A automação usa essas coordenadas, velocidade padrão 100 e coleta de 50 studs; não aplica as outras opções de TrinketBot do JSON.

| Ponto | Ação |
| --- | --- |
| P1–P2 | Aproximação em Alana |
| PE3 | Espera da coleta |
| P4 | Coleta de Silver e poções |
| P5 | Compra da espada local |
| P6–P7 | Aproximação ao Shrine |
| PE8 | Espera do farm de XP |
| P9 | Entrada da cela |
| P10 | Saída e espera de Danger |
| PG11 | Marcar spawn em Renova, sem Gate |
| P12 | Aproximação em Renova |
| PE13 | Espera da receptora |
| P14 | Receptora ativa para Rots |

A remoção da aba de gravação de pontos não apaga arquivos de pontos existentes nem muda `routes/Blade.json`.

## Estabilidade durante a execução

O loop principal cede pelo menos 0,1 segundo após cada chamada de uma etapa Blade, mesmo quando uma falha de movimento ou personagem ausente retorna imediatamente. Isso limita a repetição de trabalho na mesma frame. A inspeção de funções no hook de `coroutine.wrap` reutiliza a decisão por até um segundo, guarda somente essa decisão (não os objetos capturados), usa chaves fracas e limita o cache a 512 entradas. Scripts internos do CoreGui/CorePackages e CoreScripts seguem a função original sem inspecionar suas capturas. As decisões das funções de jogo são reavaliadas após o prazo; o mecanismo existente de limpeza dos hooks permanece.

Essas correções tratam caminhos identificados no código. Não medem o consumo do Roblox/Potassium e não comprovam que três clientes rodarão sem crash; a validação com as contas reais ainda é necessária.

## Validação

O runtime passou pela compilação Luau. Cinquenta e um testes verificam as coordenadas e a interface, filas locais, coleta e limites por método, espera inicial de HP cheio, contagem com cura, espada seguida de socos, carga de mana, saída por P10, turnos de P14, bloqueios das fornecedoras e wipe antes do rejoin. Também verificam pouso, mil atualizações sem nova subida, tentativas de compra com falha e confirmação de inventário, e coleta sem aproximação às bolsas.

Para executar os testes de rota com o CLI oficial Luau instalado:

```sh
LUAU_BIN=/caminho/para/luau python3 -m unittest discover -s tests -p test_route14.py -v
```

A máscara de nomes do Esc agrupa mudanças de Text/Image e aplica no máximo 32 atualizações ou 2 ms de trabalho por frame. Não reescreve a propriedade dentro do próprio evento, evitando realimentação com o menu do Roblox. A descoberta inicial da interface percorre os filhos por lotes de até 40 nós ou 2 ms, e os eventos de elementos destruídos são desconectados. Raízes já analisadas não repetem a busca completa a cada atualização. Os testes simulam conflito de escrita com o Roblox, 500 menus destruídos e limite de trabalho por frame. A melhora física de desempenho precisa ser conferida no cliente.

Os testes usam trechos reais do runtime com serviços simulados. Movimentação física, hitboxes, diálogos e o fluxo completo com várias contas ainda precisam de teste dentro do jogo.

## Diagnóstico de RAM na execução

O loader bloqueia outro carregamento enquanto a mesma instância está carregando ou ativa. Para atualizar, use Unload antes. O descarregamento restaura os hooks iniciais após limpar os recursos das funcionalidades e remove o evento de respawn; chamadas repetidas de Unload não repetem a limpeza.

**Settings → Diagnostico Blade 23 → Copiar diagnostico de RAM** copia um relatório local com executor, etapas de inicialização, memória Lua, memória total do cliente quando as APIs estão disponíveis e nomes das opções ativas. O histórico mantém no máximo 64 amostras, com atualização de 5 segundos após carregar. O relatório não é enviado automaticamente.

Se o Roblox fechar antes de abrir a interface, o último registro está em `sentinel/.cache/blade23_ram_diagnostic.json`. Antes de carregar novamente o bot, copie esse registro pelo executor:

```lua
setclipboard(readfile("sentinel/.cache/blade23_ram_diagnostic.json"))
```

Os testes simulam 100 ciclos de instalação e remoção de hooks, falha parcial, execução duplicada, histórico limitado e Unload reentrante. Eles não medem o pico real de RAM do Roblox ou do executor.
