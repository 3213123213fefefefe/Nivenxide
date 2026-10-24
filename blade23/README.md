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

**Proximity Check**, **Skip Illusionist Server** e **Stay In Server** têm controles separados para Gaia e Khei. Com Stay In Server e uma ameaça configurada, o Sigil salva o progresso, encerra o trabalhador e vai ao menu no mesmo servidor. Aguarda **Play manual** e o personagem reaparecer antes de retomar a etapa salva. Ao retomar o XP, reaplica a espera de entrada da cela e dos mobs, preservando os contadores. **Parar Sigil** cancela a retomada pendente. A opção **Menu por Illusionist quando Super (Gaia)** pode solicitar esse menu mesmo sem Stay In Server. Em **Khei**, Proximity e Skip Illusionist não dependem do Allow hops da rota Gaia: Stay In Server ligado pede menu e Play manual; desligado aciona o hop existente. Em **Gaia**, o controle Allow hops continua sendo respeitado. Proximity igual a 0 desliga somente essa detecção por distância. O detector do bot mantém a tolerância inicial existente de cinco segundos ao iniciar o bot.

Skip Illusionist procura Observe na mochila/personagem, o marcador Observing ou o efeito MindMage existente; Observe na mochila pode ser reconhecido mesmo antes do personagem aparecer. Gaia mantém a exigência de Super para essa reação, e Khei usa sua própria opção. Aliados selecionados, alts e clientes locais reconhecidos continuam excluídos. A fuga automática em Danger não pode passar por cima de Stay In Server para disparar um hop. O retorno ao menu continua sujeito à liberação de Danger pelo fluxo existente do jogo.

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

O farm soma as quedas individuais de HP até **6.700 de dano com espada**, depois desequipa a arma, confirma **3 socos sem carregar mana** para desbloqueá-la e faz **300 de dano com socos de mana**, em sequências de quatro M1 após cada carga até aproximadamente 95% de mana. O alcance dos socos é de aproximadamente 5 studs. Curas atualizam a referência de HP sem somar nem subtrair do contador. Os contadores de espada, socos sem mana (um por M1 confirmado, mesmo atingindo vários mobs) e dano com mana são salvos por conta para retomada. O dano dos três socos iniciais não é somado à meta dos socos de mana. A confirmação de carga em 95% é capturada antes de soltar a mana e da espera de liberação; a queda passiva nesse intervalo não cancela a sequência. O bot espera o marcador Charge desaparecer antes dos quatro M1 e respeita o término de LightAttack entre eles. Auto Charge, Snap Train e Train Climb cedem o controle durante os socos normais e a sequência de mana; a liberação também solta G caso a carga tenha começado pelo teclado. Os três socos normais continuam exigindo um M1 com dano confirmado por soco. Eles aguardam até dois segundos para a espada sair e até dois segundos para o marcador Charge desaparecer; uma falha libera o controle da mana e permite nova tentativa sem zerar hits confirmados. Se a conta sair do ponto de ataque, tenta voltar andando ao ponto quando piso e trecho direto estão livres. Essa recuperação não repete a checagem de HP cheio durante o farm. Sem alvo visível no alcance de 5 studs, a interface informa o motivo da espera.

A mira procura atingir o maior número de alvos dentro do alcance estimado, usando a direção e pequenos ajustes de posição na cela. A geometria é uma estimativa; a eficácia física deve ser conferida no jogo.

Ao concluir, sai por P10 e espera o Danger desaparecer antes de avançar. A vaga de XP só é liberada após sair do local de farm.

### Orderly e treino

**Rots:** PG11 executa a marcação de spawn em **Renova Town**, sem lançar Gate. A conta segue P12 → PE13, espera sua vez e só então entra em P14. O Master troca automaticamente pela fila. O mínimo de Shriekers usa o valor atual configurado na interface, inclusive na retomada; cada participante verifica seu próprio mínimo. Após **16 entregas confirmadas**, avança para o treino e libera a próxima receptora. Cada entrega tem uma transação própria, armada assim que o colo é confirmado, antes de caminhar ao NPC. A deduplicação é por entrega: a mesma personagem pode gerar novos Rots depois de uma nova coleta válida. O contador exige a liberação do colo estável por 0,5 segundo e uma confirmação: **Jailed** nessa vítima, ou o retorno positivo específico do NPC junto com a remoção/substituição do personagem da vítima. Essa alternativa cobre wipe/rejoin rápido em que a receptora não observa a tag. A frase sozinha, a queda do colo sozinha ou um respawn sozinho não contam. A confirmação aguarda até 12 segundos, sem buscar outra vítima nesse intervalo. Eventos repetidos e replays do diálogo não somam novamente a mesma transação. Quatro entregas de cada uma de quatro vítimas podem somar 16 mesmo quando uma vítima reutiliza seu personagem. Uma entrega pendente fica preservada durante a pausa por menu para ser resolvida na retomada. O progresso parcial é salvo em cada entrega e retomado na mesma execução; a interface diferencia a contagem da etapa (0–16) do total histórico. O botão de zerar total fica bloqueado com bots, fila ou entrega ativos. Contagens antigas não são corrigidas por estimativa.

**Quests:** usa a sequência existente de missões e poções. O treino de Warrior compra apenas **Pommel Strike**, **Action Surge** e **Plate Training** com Alfric, com limite persistente de três compras confirmadas, considerando também skills já obtidas. Respostas de pagamento duplicadas no mesmo diálogo são bloqueadas antes do envio. Se faltar Silver, Orderly ou XP, permanece no trainer, coleta Silver próximo e tenta novamente após 15 segundos. Não refaz a estalagem e a viagem entre cada tentativa. Em Castle Sanctuary, visita Draug logo após marcar spawn, usa o diálogo existente e confirma a conversa antes de ir a Jagen. Aguarda a compra e a confirmação da skill Ultra de Jagen e segue diretamente à finalização ou a Ya'alda/Khei, conforme a opção existente. A rota Blade/Sigil não carrega mana nem espera Mana Dash depois da Ultra. Retomadas antigas removem os marcadores dessa espera, preservando o progresso e o farm de socos de mana. A rota Blade não desvia para o day farm em Santorini antes dessa compra.

## Escolher a etapa manualmente

Em **blade 23 → Blade / Sigil**, clique **Parar Sigil**, aguarde a rotina terminar, selecione **Etapa ao iniciar (manual)** e clique **Iniciar Sigil**. A troca é aplicada somente nesse clique; carregar configurações ou retomar após menu/hop não aplica uma nova escolha automaticamente. Após uma inicialização bem-sucedida, o seletor volta para **Resume**. Se a inicialização falhar, a escolha permanece disponível para tentar novamente.

As opções são início em Alana/coleta, compra da espada, XP de espada e socos, saída do XP/espera de Danger, Orderly por Rots ou Quests, skills de Warrior/Sigil e Draug/Ultra com Jagen. **Khei - retomar sequencia** exige que a conta já esteja em Khei; as etapas Gaia exigem o mapa Gaia.

A escolha preserva dano/XP, socos confirmados, Rots, skills e o runId salvos. Uma parte já concluída pode avançar automaticamente. Ela não concede XP, Silver, Orderly ou skills no jogo e não zera os contadores. As verificações reais dos NPCs continuam valendo. Para repetir todo o processo do zero, existe o botão separado Reset Progress.

Etapas avançadas não refazem a viagem inicial até Alana. Escolher o início em Alana refaz a vinculação dessa etapa. Base/super e Ultra não exigem configurar alts de Rot ou o controlador de treino de mana de etapas anteriores. A opção usa o mesmo identificador de configuração existente e participa do salvamento automático e Save Config.

## Contas fornecedoras de Rot

Na subaba **Rot**, habilite Blatant Mode, ajuste a retomada após rejoin e a tecla de parada e clique **Iniciar Rot**. Não inicie a progressão Sigil nessa mesma conta. O botão inicia o papel de fornecedora e não exige Master manual.

A preparação existente em Santorini/Shore 4 mantém as condições de Rot. Em Renova, a fornecedora espera em `(-2085.454589844, 609.353881836, -754.801147461)`. A vítima escolhe qualquer outro jogador vivo e livre a até 6 studs na horizontal de P14, com tolerância de 12 studs na altura. A identificação vem dos personagens presentes no servidor e funciona mesmo quando a receptora está em outro PC, sem registro compartilhado ou Master manual. Vítimas conhecidas do Rot Bot no mesmo PC são excluídas. Enquanto a pessoa carrega outra conta, está downada ou fora do ponto, as fornecedoras aguardam. Por presença não é possível ler a contagem de 16 Rots do outro PC: a receptora deve sair do ponto quando terminar. A progressão Blade / Sigil normalmente faz isso ao seguir ao treino.

A vítima usa o voo temporário existente do Sentinel para chegar ao Master e só se downa quando está próxima e a receptora continua livre. A receptora anda até a conta downada, carrega e entrega no Bounty Officer de Renova usando o pathfinder existente. Após a entrega, prioriza a alt selecionada downada e livre mais próxima, sem voltar primeiro a P14 se já houver outra vítima pronta. Contas já presas, carregadas ou na fila de receptoras são ignoradas. Ter contado uma entrega anterior não exclui uma alt que voltou a estar downada e livre para uma nova coleta. Se não houver vítima pronta, retorna a P14 para permitir a aproximação das fornecedoras. Uma tentativa de coleta que falha dá dois segundos de prioridade às outras vítimas elegíveis. O Carry continua sendo solicitado no máximo a cada 0,25 segundo, com confirmação consultada a cada 0,05 segundo; uma troca de personagem cancela a tentativa. O diálogo de entrega pode encerrar assim que a prisão da vítima e a liberação do colo forem observadas. O contador continua exigindo a estabilização de 0,5 segundo e não usa a frase do NPC como confirmação. A fornecedora executa wipe/respawn antes do rejoin. A retomada pressiona Play antes de iniciar a preparação, inclusive quando o menu já contém um personagem provisório. A opção de retomada usa o loader do GitHub após a troca de servidor; o executor precisa oferecer `queue_on_teleport` ou `queueteleport` e permitir a execução após a troca.

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

O loop principal cede pelo menos 0,1 segundo após cada etapa, incluindo as etapas legadas de Ultra/Khei, mesmo quando uma falha de movimento ou personagem ausente retorna imediatamente. Isso limita tentativas sem espera no mesmo frame.

No hook de `coroutine.wrap`, executores que oferecem `debug.getinfo(...).nups` e `debug.getupvalue` usam metadados e leitura individual, evitando criar uma tabela com todas as variáveis capturadas a cada função nova. O caminho anterior permanece como compatibilidade quando essas APIs não existem ou falham. O cache conserva apenas a decisão por até um segundo, usa chaves fracas e tem limite de 512 entradas. A inspeção tem trava por coroutine para não entrar recursivamente no próprio hook. CoreGui/CorePackages e CoreScripts continuam seguindo a função original. O descarregamento continua restaurando os hooks.

A busca de funções do leaderboard é serializada também na inicialização, percorre lotes de até 64 entradas ou 2 ms antes de ceder e termina quando a interface é destruída ou o script é descarregado. Ela não força uma coleta completa de lixo. O salvamento automático de preferências e a atualização de presença local impedem novas execuções enquanto a chamada anterior ao executor ainda está pendente.

As opções e as rotinas de XP, mana, ROT, skills, movimentação e segurança foram preservadas nesta revisão. As opções existentes de economia de GPU em segundo plano também continuam disponíveis. Uso baixo de CPU/GPU, isoladamente, não distingue essa economia de um travamento real. As correções tratam caminhos identificados no código; não comprovam estabilidade do Roblox/Potassium com três clientes.

## Validação

O runtime passou pela compilação Luau. Setenta e três testes verificam as coordenadas e a interface, filas locais, coleta e limites por método, espera inicial de HP cheio, contagem com cura, espada seguida de socos, carga de mana, saída por P10, turnos de P14, bloqueios das fornecedoras e wipe antes do rejoin. Também verificam pouso, mil atualizações sem nova subida, tentativas de compra com falha e confirmação de inventário, e coleta sem aproximação às bolsas.

Para executar os testes de rota com o CLI oficial Luau instalado:

```sh
LUAU_BIN=/caminho/para/luau python3 -m unittest discover -s tests -p test_route14.py -v
```

As máscaras de nomes do Esc, StatGui e leaderboard aplicam mudanças fora dos eventos de Text/Image. Duas filas FIFO, uma para a máscara local/menu e outra para o scramble do leaderboard, coalescem trabalho por objeto; cada fila verifica o limite de 32 atualizações ou 2 ms por frame. Eventos imediatos e diferidos não iniciam outra aplicação recursiva. Objetos destruídos saem da fila e perdem seus listeners; tarefas antigas não escrevem depois da limpeza. Um nome que contém o próprio username não cresce a cada evento. A descoberta inicial da interface continua em lotes de até 40 nós ou 2 ms. Abrir e fechar Esc rapidamente reutiliza um único worker, cuja espera não depende de RenderStepped.

Os testes simulam 200 reaberturas de Esc, eventos de texto imediatos e diferidos, conflito de escrita com a interface, 500 menus destruídos, filas com objetos removidos e leituras que cedem, além de chamadas lentas/recursivas do executor. Também verificam a inspeção individual com cache, a busca do leaderboard em lotes e tentativas de etapas legadas que retornam imediatamente.

Os testes usam trechos reais do runtime com serviços simulados. Movimentação física, hitboxes, diálogos e o fluxo completo com várias contas ainda precisam de teste dentro do jogo.

## Diagnóstico de RAM na execução

O loader bloqueia outro carregamento enquanto a mesma instância está carregando ou ativa. Para atualizar, use Unload antes. O descarregamento restaura os hooks iniciais após limpar os recursos das funcionalidades e remove o evento de respawn; chamadas repetidas de Unload não repetem a limpeza.

**Settings → Diagnostico Blade 23 → Copiar diagnostico de RAM** copia um relatório local com executor, etapas de inicialização, memória Lua, memória total do cliente quando as APIs estão disponíveis e nomes das opções ativas. O histórico mantém no máximo 64 amostras, com atualização de 5 segundos após carregar. O relatório não é enviado automaticamente.

Se o Roblox fechar antes de abrir a interface, o último registro está em `sentinel/.cache/blade23_ram_diagnostic.json`. Antes de carregar novamente o bot, copie esse registro pelo executor:

```lua
setclipboard(readfile("sentinel/.cache/blade23_ram_diagnostic.json"))
```

Os testes simulam 100 ciclos de instalação e remoção de hooks, falha parcial, execução duplicada, histórico limitado e Unload reentrante. Eles não medem o pico real de RAM do Roblox ou do executor.
