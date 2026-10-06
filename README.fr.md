# Get-UserScheduledTasks

> Inventaire des tâches planifiées Windows personnalisées sur les serveurs Active Directory, avec rapports HTML et CSV.

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.0.0-informational.svg)](CHANGELOG.md)

[English version](README.md)

---

## Présentation

`Get-UserScheduledTasks.ps1` interroge des serveurs Windows via WinRM et liste les tâches planifiées qui ne sont pas fournies avec le système (tout ce qui est hors de `\Microsoft\*`). Il met en évidence les configurations à risque, comme une tâche avec mot de passe stocké ou un compte nominatif au niveau d'exécution le plus élevé, et produit un rapport HTML autonome et triable ainsi qu'un export CSV. Le script est en lecture seule : il ne crée, ne modifie et ne supprime aucune tâche.

---

## Fonctionnalités

- Liste des serveurs issue d'Active Directory (Windows Server uniquement) ou fournie manuellement
- Collecte en parallèle via `Invoke-Command`, avec limite de parallélisme configurable
- Par tâche : chemin, nom, état, auteur, compte d'exécution, type de connexion, niveau d'exécution, déclencheurs, actions, dernier/prochain run, dernier résultat
- Alertes : identifiants stockés, compte nominatif en privilèges maximum, dernier run en erreur, tâche désactivée, tâche illisible
- Comptes intégrés et comptes de service connus détectés par SID, donc indépendamment de la langue du système
- Tâches d'éditeurs tiers classées à part ; bruit Windows/installeurs connu masqué par défaut
- Rapport HTML autonome (thème clair, hors ligne, aucune requête externe) : cartes cliquables, recherche plein texte, filtres, colonnes triables, lignes dépliables, export CSV des lignes filtrées
- Erreurs de collecte signalées par serveur au lieu d'être perdues silencieusement

---

## Prérequis

| Dépendance | Version |
|------------|---------|
| PowerShell | >= 5.1 |
| Module ActiveDirectory (RSAT) | Uniquement si `-ComputerName` n'est pas utilisé |
| WinRM activé sur les cibles | Windows Server 2012 ou supérieur (nécessite `Get-ScheduledTask`) |
| Droits | Administrateur local sur les serveurs cibles |

---

## Installation

```bash
git clone https://github.com/9LivesITSolutions/Get-UserScheduledTasks.git
cd Get-UserScheduledTasks
```

Le script est enregistré en UTF-8 avec BOM pour que Windows PowerShell 5.1 lise correctement les accents. Conserve le BOM si tu le modifies.

---

## Utilisation

```powershell
# Tous les serveurs Windows activés du domaine
.\Get-UserScheduledTasks.ps1

# Serveurs précis
.\Get-UserScheduledTasks.ps1 -ComputerName srv01,srv02

# Limiter à une OU, masquer les tâches éditeurs
.\Get-UserScheduledTasks.ps1 -SearchBase "OU=Servers,DC=contoso,DC=local" -ExcludeVendor

# Identifiants alternatifs
.\Get-UserScheduledTasks.ps1 -ComputerName srv01 -Credential (Get-Credential)
```

---

## Paramètres

| Paramètre | Défaut | Description |
|-----------|--------|-------------|
| `-ComputerName` | serveurs AD | Serveurs à interroger |
| `-SearchBase` | tout le domaine | OU utilisée pour la requête AD |
| `-ExcludeVendor` | désactivé | Masque les tâches classées comme éditeurs tiers |
| `-NoisePattern` | voir le script | Regex (début du nom) des tâches Windows/installeurs masquées par défaut |
| `-IncludeNoise` | désactivé | Affiche les tâches correspondant à `-NoisePattern` |
| `-ThrottleLimit` | `32` | Nombre de serveurs interrogés en parallèle |
| `-OutputPath` | `.\Output` | Dossier de sortie |
| `-Credential` | utilisateur courant | Identifiants utilisés pour la connexion distante |

---

## Sorties

| Fichier | Contenu |
|---------|---------|
| `ScheduledTasks_<horodatage>.html` | Rapport interactif |
| `ScheduledTasks_<horodatage>.csv` | Toutes les tâches (séparateur `;`, UTF-8 avec BOM) |
| `Unreachable_<horodatage>.csv` | Erreurs de collecte par serveur (uniquement s'il y en a) |

### Alertes

| Alerte | Signification |
|--------|---------------|
| `MotDePasseStocké` | Compte nominatif avec un type de connexion `Password` ou `InteractiveOrPassword` |
| `CompteNominatif+Highest` | Compte nominatif exécuté au niveau le plus élevé |
| `DernierRunEnErreur` | Dernier résultat ni succès, ni en cours, ni jamais exécuté |
| `ErreurLecture` | Tâche trouvée mais définition illisible ; détail dans la description |
| `Désactivée` | Tâche désactivée |

---

## Limites

- `MotDePasseStocké` est déduit du type de connexion. L'API du planificateur n'indique pas si un mot de passe est réellement stocké : l'alerte est une forte présomption, pas une preuve.
- Les tâches sous `\Microsoft\*` sont exclues, y compris une tâche personnalisée qui y serait rangée.
- Les tâches planifiées en cluster ne sont pas retournées par `Get-ScheduledTask` et ne sont pas couvertes.
- Les serveurs dont l'attribut `OperatingSystem` est vide dans Active Directory ne sont pas retournés par la recherche automatique.

---

## Structure du projet

```
Get-UserScheduledTasks/
├── Get-UserScheduledTasks.ps1   # Script de collecte et modèle HTML
├── README.md
├── README.fr.md
└── CHANGELOG.md
```

---

## Contribuer

1. Fork du dépôt
2. Création d'une branche (`git checkout -b feature/ma-fonctionnalite`)
3. Commit (`git commit -m 'feat: ajoute ma-fonctionnalite'`)
4. Push de la branche (`git push origin feature/ma-fonctionnalite`)
5. Ouverture d'une Pull Request

Merci de suivre les [Conventional Commits](https://www.conventionalcommits.org/) pour les messages de commit.

---

## Licence

Ce projet est distribué sous licence MIT — voir le fichier [LICENSE](LICENSE) pour le détail.

---

Maintenu par **9 Lives IT Solutions**.
