import { PrismaClient } from '@prisma/client';
import { seedCharacters } from '../src/seed/characters.js';

const prisma = new PrismaClient();

async function main() {
  console.log(`Seeding ${seedCharacters.length} characters...`);

  for (const character of seedCharacters) {
    // Official characters have no creator, so name+universe is their identity.
    const existing = await prisma.character.findFirst({
      where: { name: character.name, universe: character.universe, creatorId: null },
      select: { id: true },
    });

    if (existing) {
      await prisma.character.update({
        where: { id: existing.id },
        data: { ...character, isFeatured: true },
      });
      console.log(`  updated  ${character.name}`);
    } else {
      await prisma.character.create({ data: { ...character, isFeatured: true } });
      console.log(`  created  ${character.name}`);
    }
  }

  console.log('Done.');
}

main()
  .catch((err) => {
    console.error(err);
    process.exit(1);
  })
  .finally(() => prisma.$disconnect());
