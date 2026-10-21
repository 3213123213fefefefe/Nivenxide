# blade 23 — dois PCs

Esta pasta contém o Sentinel modificado, um loader remoto, um servidor de comunicação e um iniciador para Windows. O servidor usa apenas a biblioteca padrão do Python 3.10 ou superior.

## 1. Ligar o PC principal

Só o PC principal precisa do Python 3.10 ou superior. Os dois PCs precisam estar na mesma rede, ou conectados por uma rede privada/VPN que permita acesso ao PC principal.

1. Feche a janela do servidor antigo se ela estiver aberta.
2. Baixe apenas **iniciar_servidor.bat** e abra-o. Ele baixa/atualiza `blade23_server.py` automaticamente na mesma pasta, preservando a configuração existente.
3. Deixe a janela do servidor aberta. Uma página **Blade 23 — conectar PCs** abre no navegador, com **Copiar convite**.
4. Se o Windows solicitar acesso à rede, permita na rede privada usada pelos PCs.

Se a página não abrir automaticamente, acesse `http://127.0.0.1:8787/` no PC principal. A página de convite só é acessível nesse PC. Ao abrir o iniciador novamente com o servidor já ligado, ele reabre essa página.

O arquivo `blade23_access_key.txt` e o banco `blade23_state.sqlite3` ficam na pasta do iniciador. As conexões já pareadas continuam válidas após reiniciar o servidor usando essa mesma pasta.

## 2. Abrir o bot

Pare a versão anterior ou reentre no jogo antes de carregar. Use o mesmo comando nos dois PCs:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/3213123213fefefefe/Nivenxide/main/blade23/loader.lua", true))()
```

A aba **blade 23** reúne **Blade / Sigil**, **Rot e filas**, **Cela XP** e **Conexao facil**. O bot carrega a versão publicada no GitHub sem baixar o `.lua` manualmente.

## 3. Conectar em dois passos

Faça a conexão com a progressão e o Rot Bot parados e fora da fila.

**No PC principal:** em **blade 23 → Conexao facil**, clique **Conectar neste PC**. A chave é obtida, testada e salva automaticamente.

**No outro PC:** na página do navegador do PC principal, clique **Copiar convite**. Envie esse texto ao segundo PC, cole em **Convite do PC principal** no bot e clique **Conectar convite**. O convite já inclui o endereço e um código curto; não é preciso preencher a chave longa.

Deve aparecer **Conectado ao Blade 23**. O convite vale por dez minutos; **Renovar convite** gera outro sem desconectar quem já conectou. Se houver mais de um endereço na página, selecione o da rede acessível pelos dois PCs.

A conexão fica salva na pasta do executor. Novas instâncias a carregam automaticamente. Instâncias já abertas que compartilham essa pasta recebem a configuração quando estiverem paradas e fora das filas. Se outro executor usa outra pasta, conecte uma vez nessa pasta também. A configuração não muda durante um farm ou turno de Rot.

Todas as contas precisam estar no **mesmo servidor do Roblox**. O servidor Python deve permanecer aberto no PC principal.

### Configuração manual, quando necessária

Ative **Mostrar configuracao manual**. Os campos anteriores continuam disponíveis; **Salvar e testar configuracao** aplica os valores digitados em uma única ação. O PC principal usa `http://127.0.0.1:8787`; o segundo usa o endereço acessível do primeiro e a chave do arquivo `blade23_access_key.txt`. Para HTTPS ou uma porta diferente, use essa seção.

## 4. Iniciar a automação

### Contas que vão virar Blade/Sigil

1. Em **Blade / Sigil**, escolha **Blade/Sigil (3 stages)**.
2. Selecione **Rots** ou **Quests**.
3. O spawn inicial **Supply spawn / inn** vem em **Alana**, usando o **Inn Keeper da cidade Alana**. Marque o ponto de coleta nessa cidade e o ponto de espera. Na primeira execução desta atualização, a seleção antiga de spawn é substituída por Alana; depois, suas alterações são preservadas. Se a preparação ainda estiver em andamento, um spawn marcado em outra cidade será remarcado antes da coleta.
4. Confira o silver inicial, padrão 660, incluindo 10 da espada. O valor é ajustável. Na opção **Rots**, a preparação coleta/exige apenas o Silver; não coleta nem espera poções. Na opção **Quests**, também exige/coleta 1 Liquid Wisdom, 1 Health Potion, 1 Ice Protection e 5 Tespian Elixir.
5. A cela padrão Necro já vem marcada. Confira a área ou calibre outra cela seguindo a seção abaixo. Confira a meta de dano, padrão 6.700, e a quantidade mínima de Shriekers, padrão 50. Para testar apenas essa cela, escolha **Shriekers** em **Blade XP preference**. **Automatic** também permite o farm alternativo de Zombie Scrooms.
6. Em **Rot e filas → Alts**, selecione somente as contas fornecedoras que serão entregues ao Officer.
7. Habilite Blatant Mode, deixe **Start Phase em Resume** e clique **Iniciar Sigil**, no topo de **Blade / Sigil**. **Parar Sigil** aparece enquanto o bot está ativo. A linha de estado mostra execução, modo obrigatório ou erro ao iniciar; uma falha de inicialização libera o botão para tentar novamente.

Na rota Blade/Sigil, a espada é comprada no objeto `BronzeSword` encontrado a até 250 studs do Inn Keeper de Alana (ou do ponto de coleta, se o keeper ainda não estiver disponível). Se a conta estiver longe de Alana, tenta retornar pelo spawn de Alana antes da compra. Se a loja local não aparecer, aguarda com uma mensagem; não usa o trajeto antigo até Santorini. A próxima etapa exige a espada confirmada no inventário.

O fluxo entra automaticamente na fila de Rots ao terminar o XP. Não é necessário ativar manualmente **Join receiver queue** nesse fluxo completo.

### Contas que fornecem os Rots

1. Em **Rot e filas**, deixe **Alts vazio**.
2. Ative **Enable Rot Bot** e habilite Blatant Mode conforme exigido pelo Sentinel.
3. Não ative a progressão nem **Join receiver queue** nessas contas.
4. Deixe **Retomar fornecedor apos hop/rejoin** ativado se quiser que a fornecedora reinicie automaticamente.

O Master é atualizado automaticamente quando uma receptora inicia o turno e quando termina as 16 entregas confirmadas.

Depois de preparar as condições de Rot, a fornecedora permanece esperando em Renova. Ela só anda até a receptora e se downa quando a receptora da vez está presente, com o Rot Bot ativo, perto de Renova, livre para pegar outra conta e ainda abaixo de 16 Rots. Enquanto a receptora carrega uma conta ou ainda não chegou, as fornecedoras esperam. Um Master preenchido manualmente não substitui essa confirmação da fila.

Use **Parar Rot Bot e cancelar retomada** para parar. A tecla padrão é **F8**, configurável em **Tecla para parar Rot Bot**. Parar cancela a retomada até ativar o Rot Bot novamente.

O rejoin busca novamente o loader do GitHub e executa a versão publicada do Blade 23. O executor precisa oferecer `queue_on_teleport` ou `queueteleport` e ter conexão com o GitHub. Não é preciso manter o script principal na workspace. Se o executor exigir reinjeção manual após trocar de servidor, faça essa etapa no executor.

### Marcar a cela exata de Sanguine Shrine

A cela padrão Necro no mapa Gaia (`5208655184`) usa o ponto de M1 `(2268.965087890625, 62.999996185302737, 783.982666015625)` e os limites enviados na calibração. Contas sem marcação salva usam esse padrão automaticamente. Marcações já salvas ou compartilhadas continuam tendo prioridade. Para substituir uma marcação antiga, com a progressão parada, clique **Cela XP → Usar cela padrao (Necro)** e depois **Salvar/compartilhar cela XP**. A lista vazia `mobs` do relatório não fixa os alvos: os Shriekers são detectados ao vivo dentro da cela.

Para marcar outra cela, faça isso com a progressão parada, usando uma conta dentro da cela desejada:

1. Vá ao ponto onde quer que o personagem dê M1, olhe para os Shriekers e clique **blade 23 → Cela XP → Marcar ponto de M1 + direcao**. A direção salva é a do personagem.
2. Vá a um canto da cela, por dentro das paredes, e clique **Marcar canto A**.
3. Vá ao canto diagonalmente oposto, ainda por dentro da mesma cela, e clique **Marcar canto B**. Os cantos delimitam um retângulo nos eixos do mapa; a área verde permite conferir o resultado.
4. Clique **Ver area e alvos da cela**. Verde mostra os limites e os alvos selecionados, azul mostra o ponto de ataque e amarelo a direção inicial. Confira se foram selecionados os 50 Shriekers desejados, sem incluir a cela vizinha. O HP é lido individualmente; a quantidade visual de contornos pode ser limitada pelo Roblox.
5. Clique **Salvar/compartilhar cela XP**. Com os dois PCs na mesma rede do Blade 23, as outras instâncias recebem a configuração em até cerca de 5 segundos. Sem rede, a marcação fica local; use o JSON para importar nos outros executores.
6. Clique **Copiar calibracao da cela** e cole o texto na conversa para revisar o lugar e a distribuição dos mobs. Também é gravado `blade23_calibracao_xp.json` na workspace do executor, quando `writefile` está disponível.

Para importar: cole o relatório em **JSON da cela**, clique **Importar calibracao**, confira a área e salve/compartilhe.

O farm verifica HP cheio apenas ao iniciar a sessão de XP. Durante o combate, soma as quedas de HP de cada Shrieker observado na área; curas só atualizam a referência do HP e não somam nem subtraem do total. A sessão mantém a mesma cela até terminar, mesmo se outra instância editar a configuração.

O M1 procura a direção com mais alvos dentro do alcance e arco estimados. Pode andar até **1,5 stud** do ponto marcado por padrão; o limite é ajustável de 0 a 3 studs. Paredes e piso são verificados antes dos passos. Se um passo ficar bloqueado, tenta atacar da posição atual. **0** desativa os passos. A câmera pode acompanhar a mira e é restaurada ao terminar.

Alcance e arco são estimativas geométricas ajustáveis, não a hitbox oficial do jogo. A contagem de dano continua vindo do HP, inclusive quando um único M1 acerta vários mobs. A eficácia da mira precisa ser conferida no jogo com sua distribuição real de Shriekers.

### Treino de Warrior com Alfric

Na rota **Blade/Sigil (3 stages)**, tanto por Rots quanto por Quests, o treino exige apenas **Pommel Strike**, **Action Surge** e **Plate Training**. Não compra uma quarta skill para satisfazer `MercenaryCarry`. Skills já obtidas são puladas; cada nova compra aguarda confirmação antes de pagar de novo. O restante da progressão segue a sequência existente.

## O que é compartilhado

- Reservas e fila dos farms de Shriekers e Zombie Scrooms.
- Fila das contas receptoras de Rot, contagem do turno e Master.
- Identificação das contas participantes do Rot Bot.
- Cela XP publicada, incluindo ponto de ataque, direção e limites. O save de XP individual não é compartilhado.

O save individual da progressão continua local. Mover a mesma conta para outro PC não transfere automaticamente esse save.

Se o servidor de comunicação ficar indisponível, as filas remotas não passam a funcionar isoladamente em cada PC. As rotinas mostram erro ou pausam suas ações de coordenação. Um participante sem atualização perde a reserva após cerca de 12 segundos. Ao voltar após expirar, recebe nova ordem de entrada.

## Se os PCs estiverem em redes diferentes

Use um endereço acessível aos dois por uma VPN privada ou hospede o serviço com HTTPS. O programa aceita certificados TLS com `--cert certificado.pem --key chave.pem`. O endereço local mostrado pelo programa só funciona dentro da rede correspondente.

## Se não conectar

- **Servidor antigo:** feche a janela Python antiga e abra o iniciador atualizado. O fluxo de convite precisa do servidor versão 2.
- **Convite expirado:** clique **Renovar convite** na página do PC principal e copie novamente.
- **Convite incorreto:** copie o texto inteiro com **Copiar convite**, incluindo o começo `B23|`.
- **Sem resposta:** confira se o servidor está aberto, se os PCs estão na mesma rede e se o endereço escolhido é acessível pelo segundo PC. Verifique a permissão do firewall na rede privada.
- **Chave antiga/HTTP 401:** use **Conectar neste PC** no host, ou um novo convite no segundo PC. Isso obtém a chave atual automaticamente.
- **Porta ocupada:** feche a janela do servidor antigo. Se o servidor versão 2 já estiver ligado, o iniciador reabre sua página.
- O executor precisa oferecer `request`, `http_request` ou função compatível e acesso a arquivos para salvar a conexão.

Foram verificados: compilação Luau, contagem de XP com cura e retomada, HP cheio apenas na entrada, filas de XP/Rot, bloqueios da fornecedora, três skills de Alfric, carregamento remoto do Blade 23 no rejoin, limites da cela e planejamento geométrico do M1. Os testes de rede cobrem autenticação HTTP, comunicação entre clientes, ordem de chegada pelo servidor, persistência e recuperação de participantes expirados. A validação física em dois PCs e dentro do jogo ainda depende do teste no seu ambiente.


A conexão fácil foi verificada com testes HTTP reais locais, casos de convite incorreto/expirado/renovado, compatibilidade das filas anteriores, cliente Luau e callbacks da interface simulados. A página de cópia/renovação foi testada por seus eventos de JavaScript. A execução do `.bat` no Windows e o pareamento físico entre seus dois PCs ainda precisam de teste nesse ambiente.


Para verificar o servidor durante desenvolvimento, execute a partir desta pasta:

```text
python -m unittest discover -s tests -v
```
