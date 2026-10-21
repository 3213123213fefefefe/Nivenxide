# Blade 23 — tudo no mesmo PC

O Sentinel usa filas em arquivos locais do executor. Configure todas as contas no mesmo PC, no mesmo servidor do Roblox e com acesso à mesma pasta de arquivos do executor. Não é necessário Python, `.bat`, endereço de servidor, convite ou teste de conexão entre computadores. Configurações remotas antigas são substituídas pelo modo local.

## Carregar e atualizar

Pare a versão anterior em **Config → Unload** ou reentre no jogo. Execute:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/3213123213fefefefe/Nivenxide/main/blade23/loader.lua", true))()
```

A aba **blade 23** contém **Blade / Sigil**, **Rot** e **Filas**. A aba independente **Pontos do mapa** permanece disponível. Os controles antigos de conexão, rota, meta de dano, marcação de coleta e Cela XP ficam ocultos; suas funções foram preservadas internamente.

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

Ao concluir, desativa a coleta, sai para P5 e libera a vaga. Compra a Bronze Sword local próxima de P5 e confirma a espada no inventário antes de continuar. Se a espada local não aparecer, aguarda; a compra não usa a loja distante de Santorini.

### XP

Shriekers usa P6 → P7 → PE8. PE8 é a espera do farm; uma conta downada espera recuperar antes de ir a P9. **Automatic** pode usar Zombie Scrooms quando sua vaga estiver disponível; **Zombie Scrooms** usa o farm original e dispensa a aproximação ao Shrine.

Antes de iniciar o combate com Shriekers, a conta exige a quantidade mínima configurada e todos os alvos da cela com HP cheio durante **5 segundos contínuos**. Essa checagem acontece apenas na entrada da sessão. A conta passa por P9 e usa o ponto de ataque fixo da cela Necro:

- Posição: `(2268.965087890625, 62.999996185302737, 783.982666015625)`.
- Cantos: `(2272.9111328125, 62.99999237060547, 791.964599609375)` e `(2265.51806640625, 62.99999237060547, 776.548583984375)`.
- Mapa: `5208655184`.

O farm soma as quedas individuais de HP até **6.700 de dano com espada**, depois desequipa a arma e faz **800 de dano com socos carregados com mana**. O alcance dos socos é de aproximadamente 5 studs. Curas atualizam a referência de HP sem somar nem subtrair do contador. Ambos os contadores são salvos por conta para retomada.

A mira procura atingir o maior número de alvos dentro do alcance estimado, usando a direção e pequenos ajustes de posição na cela. A geometria é uma estimativa; a eficácia física deve ser conferida no jogo.

Ao concluir, sai por P10 e espera o Danger desaparecer antes de avançar. A vaga de XP só é liberada após sair do local de farm.

### Orderly e treino

**Rots:** PG11 executa a marcação de spawn em **Renova Town**, sem lançar Gate. A conta segue P12 → PE13, espera sua vez e só então entra em P14. O Master troca automaticamente pela fila. Após **16 entregas confirmadas**, avança para o treino e libera a próxima receptora.

**Quests:** usa a sequência existente de missões e poções. O treino de Warrior compra apenas **Pommel Strike**, **Action Surge** e **Plate Training** com Alfric, confirmando cada compra e pulando skills já obtidas. As etapas posteriores usam a progressão existente.

## Contas fornecedoras de Rot

Na subaba **Rot**, habilite Blatant Mode, ajuste a retomada após rejoin e a tecla de parada e clique **Iniciar Rot**. Não inicie a progressão Sigil nessa mesma conta. O botão inicia o papel de fornecedora e não exige Master manual.

A preparação existente em Santorini/Shore 4 mantém as condições de Rot. Em Renova, a fornecedora espera em `(-2085.454589844, 609.353881836, -754.801147461)`. Só se aproxima e se downa quando a receptora da vez está fisicamente em P14, livre, ativa e abaixo de 16 Rots. Enquanto a receptora carrega outra conta ou ainda está a caminho, as fornecedoras aguardam.

A receptora anda até a conta downada, carrega e entrega no Bounty Officer de Renova usando o pathfinder existente. Após a entrega, retorna à região de P14 antes de buscar outra conta. A fornecedora executa wipe/respawn antes do rejoin. A opção de retomada usa o loader do GitHub após a troca de servidor; o executor precisa oferecer `queue_on_teleport` ou `queueteleport` e permitir a execução após a troca.

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

A aba **Pontos do mapa** salva nome, observação, mapa, XYZ e direção do personagem em `sentinel/.cache/map_points.json`. Permite atualizar, exportar JSON, copiar `Vector3.new(...)` e excluir pontos. Salvar pontos não altera a rota nem movimenta o personagem.

## Validação

O runtime passou pela compilação Luau. Nove testes verificam as coordenadas e a interface, filas locais, coleta e limites por método, espera inicial de HP cheio, contagem com cura, espada seguida de socos, carga de mana, saída por P10, turnos de P14, bloqueios das fornecedoras e wipe antes do rejoin.

Para executar os testes de rota com o CLI oficial Luau instalado:

```sh
LUAU_BIN=/caminho/para/luau python3 -m unittest discover -s tests -p test_route14.py -v
```

Os testes usam trechos reais do runtime com serviços simulados. Movimentação física, hitboxes, diálogos e o fluxo completo com várias contas ainda precisam de teste dentro do jogo.
